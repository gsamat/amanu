// @preconcurrency: AVFAudio predates Sendable annotation, and its callback
// types (AVAudioNodeTapBlock, AVAudioConverterInputBlock) are declared
// @Sendable while the buffers they hand you are not. Both run synchronously on
// the thread that invokes them, so the diagnostics are annotation debt in the
// SDK rather than races here — the state genuinely shared across threads is
// the locked LockedState below.
@preconcurrency import AVFoundation
import Foundation
import os.lock

/// Records the default input device to a mono PCM file via AVAudioEngine.
/// Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// Raw capture is the default so recording never reroutes or attenuates what
/// the person hears. With voice processing explicitly enabled, Apple's echo
/// canceller subtracts speaker playback from the mic. VoiceProcessingIO is a
/// duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
///
/// A route change mid-meeting rebuilds the engine, and the rebuild keeps both
/// of those properties: the chosen processing mode and the same wall clock.
/// Losing either is silent at the time and obvious a day later — see
/// `restartCapture`.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    /// One mid-session capture restart: something reconfigured the input
    /// device under us — a call app engaging voice processing, headphones
    /// connecting, AirPods coming out of an ear — and the engine had to be
    /// rebuilt on the new route.
    ///
    /// Recorded because the two things that go wrong here are invisible while
    /// they happen. On 2026.08.20 one call restarted twice; the only surviving
    /// evidence was two short pads in the waveform, and the cost of reading it
    /// that way was an afternoon of cross-correlating the tracks.
    struct Restart {
        let at: Date
        /// Dead span written as silence, filled in by the first buffer the new
        /// engine delivers — nothing before that knows how long the route took
        /// to come back.
        var gapMs: Int?
        /// Silence actually written, when less than the gap: see
        /// `longestPad`. Absent when the whole gap was padded.
        var paddedMs: Int?
        var voiceProcessing: Bool?
        var inputWas: String?
        var inputNow: String?
        var outputWas: String?
        var outputNow: String?

        func meta(iso: ISO8601DateFormatter) -> [String: Any] {
            var fields: [String: Any] = ["at": iso.string(from: at)]
            if let gapMs { fields["gap_ms"] = gapMs }
            if let paddedMs { fields["padded_ms"] = paddedMs }
            if let voiceProcessing { fields["voice_processing"] = voiceProcessing }
            if let inputWas { fields["input_was"] = inputWas }
            if let inputNow { fields["input_now"] = inputNow }
            if let outputWas { fields["output_was"] = outputWas }
            if let outputNow { fields["output_now"] = outputNow }
            return fields
        }
    }

    /// What the microphone capture actually did, rather than what the config
    /// asked it to do. The distinction is the point of the experiment: a voice
    /// route can refuse to start or can begin with signal and later fall back
    /// to raw capture after a liveness failure or restart storm.
    struct Capture {
        let requestedVoiceProcessing: Bool
        let initialVoiceProcessing: Bool
        let finalVoiceProcessing: Bool
        let inputDevice: String?
        let outputDevice: String?
        let sampleRate: Double?
        let channels: Int?
        let sampleFormat: String?

        var meta: [String: Any] {
            var fields: [String: Any] = [
                "requested_voice_processing": requestedVoiceProcessing,
                "initial_voice_processing": initialVoiceProcessing,
                "final_voice_processing": finalVoiceProcessing,
                "fell_back_to_raw": requestedVoiceProcessing
                    && (!initialVoiceProcessing || !finalVoiceProcessing),
            ]
            if let inputDevice { fields["input_device"] = inputDevice }
            if let outputDevice { fields["output_device"] = outputDevice }
            if let sampleRate { fields["sample_rate_hz"] = Int(sampleRate.rounded()) }
            if let channels { fields["channels"] = channels }
            if let sampleFormat { fields["sample_format"] = sampleFormat }
            return fields
        }
    }

    private var engine = AVAudioEngine()
    private let liveAudio = LiveAudioBufferRelay()
    private var url: URL?
    private(set) var isRecording = false
    private var requestedVoiceProcessing = false
    private var initialVoiceProcessing = false
    private var finalVoiceProcessing = false
    private var initialInputDevice: String?
    private var initialOutputDevice: String?
    private var captureSampleRate: Double?
    private var captureChannels: Int?
    private var captureSampleFormat: String?

    var capture: Capture {
        Capture(
            requestedVoiceProcessing: requestedVoiceProcessing,
            initialVoiceProcessing: initialVoiceProcessing,
            finalVoiceProcessing: finalVoiceProcessing,
            inputDevice: initialInputDevice,
            outputDevice: initialOutputDevice,
            sampleRate: captureSampleRate,
            channels: captureChannels,
            sampleFormat: captureSampleFormat)
    }

    // Thread-safe shared state: accessed from both the main thread and the
    // audio-tap callback (background audio thread) without further sync.
    private struct LockedState {
        var file: AVAudioFile?
        /// What the taps write through. Replaced whenever `file` is, and
        /// kept across a mid-session rebuild along with it.
        var writer: TrackWriter?
        var firstBufferAt: Date?
        var lastBufferAt: Date?
        var lastSoundAt: Date?
        var levelMeasurable = true
        var muted = false
        /// Every restart, and the dead span still open. Opened on the main
        /// thread when capture is torn down, closed by the tap callback whose
        /// buffer ends it.
        var log = RestartLog()
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    private var file: AVAudioFile? {
        get { state.withLockUnchecked { $0.file } }
        set {
            state.withLockUnchecked {
                $0.file = newValue
                $0.writer = newValue.map { TrackWriter(file: $0, label: "mic") }
            }
        }
    }

    private var writer: TrackWriter? { state.withLockUnchecked { $0.writer } }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date? {
        get { state.withLock { $0.firstBufferAt } }
        set { state.withLock { $0.firstBufferAt = newValue } }
    }

    /// Wall-clock time of the most recent captured buffer. When a device
    /// reconfiguration kills the engine, the span from here to the restart is
    /// written as silence so downstream timestamps stay wall-clock aligned.
    /// Written from the tap callback and read on main during a restart, so it
    /// belongs under the same lock as the rest.
    private var lastBufferAt: Date? {
        get { state.withLock { $0.lastBufferAt } }
        set { state.withLock { $0.lastBufferAt = newValue } }
    }

    /// Wall-clock time of the last buffer that carried something louder than
    /// the noise floor. nil means nothing audible has been captured yet.
    var lastSoundAt: Date? { state.withLock { $0.lastSoundAt } }

    /// False once a buffer arrived in a sample format we can't measure —
    /// callers must then treat "silent" as "unknown" rather than as silence.
    var levelMeasurable: Bool { state.withLock { $0.levelMeasurable } }

    /// Every route change this session survived, in order. Read on stop, for
    /// meta.json.
    var restarts: [Restart] { state.withLock { $0.log.entries } }

    /// While muted, capture continues but silence is written in place of the
    /// real audio: the file keeps growing on the wall clock, so timestamps
    /// after the pause stay true, and nothing said in the room is recorded.
    var isMuted: Bool {
        get { state.withLock { $0.muted } }
        set { state.withLock { $0.muted = newValue } }
    }

    // Main-thread only: the observer hands every configuration change to the
    // main queue and handleConfigChange runs there, so these need no lock.
    private var configObserver: NSObjectProtocol?
    private var restartPending = false
    /// The route the current engine attached to, so a restart can say what
    /// changed rather than only that something did.
    private var inputDevice: String?
    private var outputDevice: String?
    /// True while the engine is writing into a file that was already open —
    /// a mid-session rebuild. It decides what a failure may throw away: at
    /// the start of a session, a silent prefix; mid-session, a meeting.
    private var attachedReusingFile = false
    /// When the current engine finished attaching, for the settle window
    /// below.
    private var attachedAt = Date.distantPast
    /// The call app families this session follows, and the device that choice
    /// currently resolves to — what capture is bound to rather than what it
    /// inherited.
    private var followedCallApps: [String] = []
    private var boundDevice: AudioObjectID?
    /// Microphones that refused this session; see `RefusedDevices`.
    private var refused = RefusedDevices()
    /// Whether the last attach bound a microphone other than the default —
    /// what `attachWithFallbacks` asks after a failure.
    private var boundChosenDevice = false
    /// Listener on the system default input, because a default that changes
    /// under a running engine changes nothing else: `AVAudioEngine` stays on
    /// the device it was built around and posts no notification at all.
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    /// How long a new microphone has to still be the answer before we move to
    /// it. A route in the middle of changing answers differently from one
    /// second to the next, and each move costs about four seconds of silence
    /// in the track.
    private static let routeSettle: TimeInterval = 1.5

    /// How long after an attach a configuration change may be our own doing.
    /// Enabling the voice unit reconfigures the input device — it builds an
    /// aggregate around it — and that posts the very notification this class
    /// restarts on, so restarting for it would start the next one.
    ///
    /// The window decides nothing by itself, because it cannot: the same
    /// notification is posted when the engine has genuinely stopped, and at
    /// the moment it arrives the two look alike. Inside the window the answer
    /// waits for `settleDeadline`, by which time a healthy engine is
    /// delivering buffers and a stopped one is not. Reading the window as
    /// "ignore it" costs a mic track — measured on 20 August 2026: 43 seconds
    /// of a 67-second recording silent, and nothing in the log but the line
    /// saying the change had been ignored.
    private static let settleWindow: TimeInterval = 1.5
    /// When that question gets answered, measured from the attach. Long enough
    /// to cover a voice-processing route's warm-up — 1.7 to 2.8 s to the first
    /// buffer on this Mac — and the worst case for how much audio a genuinely
    /// dead engine costs before it is rebuilt.
    private static let settleDeadline: TimeInterval = 5
    /// A buffer this recent means capture is alive.
    private static let aliveWithin: TimeInterval = 1
    /// Restarts within this window of each other, and the number of them that
    /// says the settle window isn't holding. Past it the route gets raw
    /// capture for the rest of the session: a track with an echo on it is a
    /// bad recording, a track rebuilt every two seconds is no recording.
    private static let stormWindow: TimeInterval = 30
    private static let stormLimit = 3

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back. The dispatch to main
    // in fallBackToRaw creates a happens-before, so these need no lock.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic as PCM in `url` (use a .caf extension — CAF
    /// needs no finalization pass, so a crash loses nothing written).
    ///
    /// `callApps` are the bundle-id families this session is following, and
    /// they decide which microphone is captured: the one the call app is
    /// listening to, falling back to the system default. Pass them again
    /// through `follow(callApps:)` when the session's idea of the call
    /// changes.
    func start(writingTo url: URL, callApps: [String] = []) throws {
        guard !isRecording else { return }
        self.url = url
        followedCallApps = callApps
        requestedVoiceProcessing = Config.micVoiceProcessing()
        try attachWithFallbacks(voiceProcessing: requestedVoiceProcessing, reusingFile: false)
        isRecording = true
        inputDevice = AudioDevices.name(of: boundDevice) ?? AudioDevices.defaultInputName()
        outputDevice = AudioDevices.defaultOutputName()
        initialVoiceProcessing = engine.inputNode.isVoiceProcessingEnabled
        finalVoiceProcessing = initialVoiceProcessing
        initialInputDevice = inputDevice
        initialOutputDevice = outputDevice
        if let format = file?.processingFormat {
            captureSampleRate = format.sampleRate
            captureChannels = Int(format.channelCount)
            captureSampleFormat = Self.name(of: format.commonFormat)
        }
        // A call app (FaceTime, Zoom) grabbing the mic reconfigures the input
        // device and stops the engine mid-session; without this observer the
        // track just ends there (2026.07.28: 1.7s mic on a 19min call).
        //
        // Delivered on the main queue, but never by making the engine wait
        // for it — see `observeConfigurationChanges`. By the time it arrives
        // the engine that posted it may already have been replaced, and a
        // change to an engine that is gone is not a change to this one.
        configObserver = Self.observeConfigurationChanges { [weak self] poster in
            guard let self, poster == ObjectIdentifier(self.engine) else { return }
            self.handleConfigChange()
        }
        listenForDefaultInputChanges()
    }

    /// Follow these call app families from now on. The route is re-examined
    /// immediately: a second app joining the call may well be the one holding
    /// the microphone.
    func follow(callApps families: [String]) {
        guard families != followedCallApps else { return }
        followedCallApps = families
        checkRoute()
    }

    /// Re-examine which microphone we ought to be on, and move if it is not
    /// the one we are on. Called on every route notification and on the
    /// session's own timer, because a call app can change device without
    /// anything system-wide changing at all.
    func checkRoute() {
        guard isRecording, !restartPending else { return }
        guard let target = routeTarget(), target != boundDevice else { return }
        // Two questions a second apart: a route in the middle of changing
        // answers differently each time, and every move costs seconds of
        // silence in the track.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.routeSettle) { [weak self] in
            guard let self, self.isRecording, !self.restartPending else { return }
            guard let now = self.routeTarget(), now == target, now != self.boundDevice
            else { return }
            let report = "mic: microphone moved to \(AudioDevices.name(of: now) ?? "?") "
                + "(was \(AudioDevices.name(of: self.boundDevice) ?? "?")) — following it\n"
            FileHandle.standardError.write(Data(report.utf8))
            self.restartPending = true
            self.restartCapture()
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        finalVoiceProcessing = engine.inputNode.isVoiceProcessingEnabled
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        stopListeningForDefaultInputChanges()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Whatever a gap left queued belongs in the file before it is let go,
        // and with the tap removed nothing more can be added.
        writer?.drain()
        file = nil
        lastBufferAt = nil
        // Nothing will arrive to close an open gap now, and the track ends
        // where the audio ended.
        state.withLock { $0.log.abandon() }
        attachedReusingFile = false
        liveAudio.install(nil)
    }

    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {
        liveAudio.install(sink)
    }

    func setLiveAudioPaused(_ paused: Bool) {
        liveAudio.isPaused = paused
    }

    // MARK: -

    /// Build the engine graph, create the PCM file, and start capture. Called
    /// once at start, again (voiceProcessing: false) if the liveness check
    /// trips, and (reusingFile: true) after a device reconfiguration.
    ///
    /// `reusingFile` changes two things and nothing else: the client format
    /// follows the open file rather than the new device, and a failure here
    /// leaves that file alone.
    private func attach(voiceProcessing: Bool, reusingFile: Bool = false) throws {
        replaceEngine()
        let input = engine.inputNode
        bindInputDevice(of: input)

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        //
        // Mid-session the rate is the open file's, not the new device's: the
        // device may well come back at another rate (48k speakers, 24k
        // AirPods) and the file's format is the one thing that cannot change.
        // Both paths convert — the voice unit between its hardware and client
        // scopes, the raw tap in `convertResampling`.
        let existing = reusingFile ? file : nil
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: existing?.processingFormat.sampleRate ?? inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat, reusingFile: existing != nil)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        if existing == nil {
            do {
                file = try AVAudioFile(
                    forWriting: url!,
                    settings: AudioFormats.pcmSettings(
                        sampleRate: monoFormat.sampleRate, channels: 1
                    ),
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
            } catch {
                input.removeTap(onBus: 0)
                throw RecorderError.fileCreationFailed(error)
            }
        }
        attachedReusingFile = existing != nil

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if existing == nil { file = nil }
            // If we had pointed it at a microphone of our own choosing, that
            // is the first suspect: it is not asked again for a while, and the
            // retry gets the default instead.
            if boundChosenDevice, let boundDevice { refused.refuse(boundDevice, at: Date()) }
            throw RecorderError.engineStartFailed(error)
        }
        attachedAt = Date()
        finalVoiceProcessing = input.isVoiceProcessingEnabled

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Start over with a fresh engine, and let the old one go somewhere
    /// other than here. Every caller has already stopped it and removed its
    /// tap, or never started it, so nothing of it is still writing; what is
    /// left is its `dealloc`,
    /// which waits for the engine's own queue — see `Retiring`.
    ///
    /// The new engine exists before the old one is released, so the two never
    /// share an address, which is what lets a configuration change be matched
    /// to its engine by identity.
    private func replaceEngine() {
        let retiring = Retiring(engine)
        engine = AVAudioEngine()
        if !retiring.release() {
            FileHandle.standardError.write(Data(
                "warning: the old mic engine is slow to go away — carrying on without waiting\n".utf8
            ))
        }
    }

    private static func name(of format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "float32"
        case .pcmFormatFloat64: return "float64"
        case .pcmFormatInt16: return "int16"
        case .pcmFormatInt32: return "int32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    ///
    /// Mid-session the window is longer, because there the check has a false
    /// positive it doesn't have at startup: the noise suppressor emits true
    /// digital zeros in a quiet room, in runs that have reached 0.9 s in a
    /// real meeting. Reading a lull as a dead route would drop echo
    /// cancellation for the rest of the call — the exact failure this restart
    /// path exists to prevent.
    private func installVoiceTap(
        on input: AVAudioInputNode, format: AVAudioFormat, reusingFile: Bool
    ) {
        let checkFrames = Int(format.sampleRate * (reusingFile ? 3 : 1))
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let writer = self.writer else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.lastBufferAt = Date()

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            self.writeTracked(buffer, to: writer)
        }
    }

    /// Write one captured buffer, recording its level on the way through and
    /// substituting silence while paused. Both taps funnel through here so the
    /// pause and the level tracking can't diverge between the two paths.
    private func writeTracked(_ buffer: AVAudioPCMBuffer, to writer: TrackWriter) {
        let silence = pendingGap(before: buffer, rate: writer.file.processingFormat.sampleRate)
        let peak = AudioLevel.peak(of: buffer)
        let muted: Bool = state.withLock { s in
            if let peak {
                if peak >= AudioLevel.speechThreshold { s.lastSoundAt = Date() }
            } else {
                s.levelMeasurable = false
            }
            return s.muted
        }

        var outgoing = buffer
        if muted {
            guard let silent = AudioLevel.silence(like: buffer) else { return }
            outgoing = silent
        }
        writer.write(outgoing, after: silence)
        liveAudio.forward(outgoing)
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        let sameRate = inputFormat.sampleRate == monoFormat.sampleRate
        let ratio = monoFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let writer = self.writer else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.lastBufferAt = Date()
            let capacity = AVAudioFrameCount(Double(buffer.frameCapacity) * ratio) + 64
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: capacity
            ) else { return }
            do {
                if sameRate {
                    try converter.convert(to: mono, from: buffer)
                } else {
                    // Post-reconfigure the device can come back at a new rate;
                    // the one-shot convert only handles equal rates.
                    try Self.convertResampling(buffer, to: mono, using: converter)
                }
            } catch {
                FileHandle.standardError.write(Data("mic downmix failed: \(error)\n".utf8))
                return
            }
            self.writeTracked(mono, to: writer)
        }
    }

    /// Feed `buffer` through `converter` exactly once, for the rate-mismatched
    /// case the one-shot `convert(to:from:)` can't handle.
    ///
    /// The "have I fed it yet" flag lives in a box rather than a local `var`:
    /// `AVAudioConverterInputBlock` is typed `@Sendable`, so Swift 6 rejects
    /// capturing a mutable local even though `convert` invokes the block
    /// synchronously on this very thread before returning.
    private static func convertResampling(
        _ buffer: AVAudioPCMBuffer,
        to mono: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) throws {
        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var convertError: NSError?
        converter.convert(to: mono, error: &convertError) { _, outStatus in
            if feed.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            feed.done = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let convertError { throw convertError }
    }

    /// Point this engine at the microphone we mean to record.
    ///
    /// Only when that is not the default one: an engine picks the default up
    /// by itself at start, so following a default that changed needs nothing
    /// but the restart. What needs saying out loud is the other case — the
    /// call app listening to a microphone the system has not been told about —
    /// and that is the only case where this touches the unit at all, which
    /// keeps a device the voice unit dislikes out of the ordinary path.
    ///
    /// A refusal is not fatal. Capture continues on the default, which is
    /// where it would have been anyway; it is logged because it means the
    /// track and the call are listening to different microphones.
    private func bindInputDevice(of input: AVAudioInputNode) {
        let fallback = AudioDevices.defaultInput()
        boundChosenDevice = false
        guard let wanted = routeTarget(), wanted != fallback else {
            boundDevice = fallback
            return
        }
        let name = AudioDevices.name(of: wanted) ?? "?"
        do {
            try input.auAudioUnit.setDeviceID(wanted)
            boundDevice = wanted
            boundChosenDevice = true
            FileHandle.standardError.write(Data(
                "mic: recording \(name), the microphone the call is on\n".utf8
            ))
        } catch {
            boundDevice = fallback
            refused.refuse(wanted, at: Date())
            FileHandle.standardError.write(Data(
                "warning: cannot record \(name) (\(error)) — using the default mic\n".utf8
            ))
        }
    }

    /// The microphone capture should be bound to now, refusals considered.
    private func routeTarget() -> AudioObjectID? {
        Self.routeTarget(
            wanted: MicRoute.preferred(callApps: followedCallApps)?.id,
            fallback: AudioDevices.defaultInput(),
            refused: refused,
            now: Date())
    }

    /// `attach`, with the retreats of `MicRecorder.attachWithFallbacks`.
    private func attachWithFallbacks(voiceProcessing: Bool, reusingFile: Bool) throws {
        try Self.attachWithFallbacks(
            voiceProcessing: voiceProcessing,
            attempt: { voice in
                do {
                    try attach(voiceProcessing: voice, reusingFile: reusingFile)
                } catch {
                    FileHandle.standardError.write(Data(
                        "mic: capture would not start (voiceProcessing=\(voice)): \(error)\n".utf8))
                    throw error
                }
            },
            failedOnChosenDevice: { boundChosenDevice })
    }

    /// Follow the system default input while recording. A default that changes
    /// under a running engine is silent in every other way — the engine stays
    /// on the device it was built around, and `AVAudioEngineConfigurationChange`
    /// is not posted — so without this listener, choosing another microphone
    /// mid-meeting leaves amanu recording the old one for the rest of the call.
    private func listenForDefaultInputChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.checkRoute() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        if status == noErr {
            defaultInputListener = listener
        } else {
            let warning = "warning: cannot watch the default microphone (\(status)) — "
                + "a mid-meeting change will not be followed\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private func stopListeningForDefaultInputChanges() {
        guard let defaultInputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main,
            defaultInputListener
        )
        self.defaultInputListener = nil
    }

    /// Another process reconfigured the input device (typically a call app
    /// engaging voice processing) and the engine stopped. Debounce briefly —
    /// reconfiguration storms post several notifications — then restart.
    private func handleConfigChange() {
        guard isRecording, !restartPending else { return }
        restartPending = true

        if Date().timeIntervalSince(attachedAt) <= Self.settleWindow, engine.isRunning {
            // Possibly our own attach reconfiguring the device — but only
            // possibly, and only while the engine is still running. An engine
            // that has stopped never restarts itself, so there is nothing to
            // wait for and the case falls through to the restart below.
            //
            // Otherwise wait for the new engine to prove itself rather than
            // guessing whose change this is: buffers still arriving at the
            // deadline means it is alive and the change was ours, and no
            // buffers means it stopped and has to be rebuilt whoever caused it.
            let wait = max(attachedAt.addingTimeInterval(Self.settleDeadline).timeIntervalSinceNow, 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.isRecording else { return }
                if self.audioIsFlowing {
                    self.restartPending = false
                    FileHandle.standardError.write(Data(
                        "mic: configuration change was our own — capture is alive\n".utf8
                    ))
                    return
                }
                FileHandle.standardError.write(Data(
                    "mic: no audio after the engine was reconfigured — restarting capture\n".utf8
                ))
                self.restartCapture()
            }
            return
        }

        FileHandle.standardError.write(Data(
            "mic: input device reconfigured (call app?) — restarting capture\n".utf8
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartCapture()
        }
    }

    /// Whether a buffer has landed since the current engine attached, recently
    /// enough to call capture alive. The only evidence that separates a device
    /// we reconfigured ourselves from one that stopped.
    ///
    /// Both halves matter. A buffer from the engine that has just been torn
    /// down says nothing about the one that replaced it, and without the first
    /// half a dead engine looks alive for a whole second after every restart.
    private var audioIsFlowing: Bool {
        guard let last = lastBufferAt, last > attachedAt else { return false }
        return Date().timeIntervalSince(last) < Self.aliveWithin
    }

    /// Rebuild the engine on the new route, keeping the file, the wall clock,
    /// and — the part this used to give away — echo cancellation.
    ///
    /// Restarting raw was justified by "during a call the call app owns echo
    /// cancellation", which is true of what Zoom sends and says nothing about
    /// what we capture. amanu taps the device itself, so dropping voice
    /// processing means the mic writes down whatever the speakers are playing.
    /// On 2026.08.20 that turned the far end into a second voice on our own
    /// track, 3 dB under the real one, for the 35 minutes between an AirPods
    /// route change and the end of the call.
    private func restartCapture() {
        restartPending = false
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // The gap is only marked here, not written: the first buffer of the
        // new engine is the only thing that knows how long the dead span
        // really was. Starting a device takes a few hundred milliseconds, and
        // padding before the start left every one of them out of the track —
        // two restarts put the mic 0.75 s ahead of the system track, far
        // enough for its echo of the far end to precede the far end.
        let now = Date()
        let (index, recent) = state.withLock { s in
            let index = s.log.open(at: now, lastBufferAt: s.lastBufferAt)
            return (index, s.log.recent(within: Self.stormWindow, of: now))
        }
        let storming = recent >= Self.stormLimit
        if storming {
            FileHandle.standardError.write(Data(
                "warning: \(recent) mic restarts in \(Int(Self.stormWindow))s — capturing raw\n".utf8
            ))
        }
        let voice = Config.micVoiceProcessing() && !storming
        do {
            // The new route may be one the voice unit can't take (rca-001), or
            // the call app's microphone may refuse us; each gives way in turn.
            try attachWithFallbacks(voiceProcessing: voice, reusingFile: true)
        } catch {
            FileHandle.standardError.write(Data("mic: retrying restart in 2s\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRecording else { return }
                self.restartCapture()
            }
            return
        }
        noteRestart(index)
    }

    /// Record what the route changed into, for meta.json and the run log.
    /// `gap_ms` is filled in by the first buffer, whenever that lands.
    private func noteRestart(_ index: Int) {
        // The microphone we are on, which is not always the default one —
        // that is the whole point of binding it.
        let input = AudioDevices.name(of: boundDevice) ?? AudioDevices.defaultInputName()
        let output = AudioDevices.defaultOutputName()
        let voice = engine.inputNode.isVoiceProcessingEnabled
        let (inputWas, outputWas) = (inputDevice, outputDevice)
        state.withLock {
            $0.log.update(index) { restart in
                restart.voiceProcessing = voice
                restart.inputWas = inputWas
                restart.inputNow = input
                restart.outputWas = outputWas
                restart.outputNow = output
            }
        }
        let report = "mic: capture restarted — in \(inputDevice ?? "?") → \(input ?? "?"), "
            + "out \(outputDevice ?? "?") → \(output ?? "?"), voiceProcessing=\(voice)\n"
        FileHandle.standardError.write(Data(report.utf8))
        inputDevice = input
        outputDevice = output
    }

    /// Close an open gap ahead of the first buffer that follows it: the
    /// frames of silence for the span between the last buffer of the old
    /// engine and the start of the audio this one carries, so the track keeps
    /// its place on the wall clock. The writer puts them in the file off this
    /// thread.
    private func pendingGap(before buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioFrameCount {
        let carried = Double(buffer.frameLength) / buffer.format.sampleRate
        return state.withLock { s -> AVAudioFrameCount in
            let index = s.log.openIndex
            guard let gap = s.log.close(now: Date(), carried: carried) else { return 0 }
            let padded = min(gap, Self.longestPad)
            if padded < gap, let index { s.log.notePadded(padded, forEntry: index) }
            return Self.silenceFrames(gap: padded, sampleRate: rate)
        }
    }

    /// Frames of silence a dead span of `gap` seconds is worth. Spans under
    /// 50 ms are left alone: buffer timing and the wall clock disagree by
    /// about that much anyway, and padding the disagreement would drift the
    /// track as surely as ignoring a real gap.
    static func silenceFrames(gap: TimeInterval, sampleRate: Double) -> AVAudioFrameCount {
        guard gap > 0.05, sampleRate > 0 else { return 0 }
        return AVAudioFrameCount(gap * sampleRate)
    }

    /// The voice-processing route delivered digital silence: tear the engine
    /// down and restart raw, discarding the silent prefix so the track's
    /// timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        if attachedReusingFile {
            // Mid-session the "silent prefix" is a meeting. Keep the file and
            // the wall clock; give up only the cancellation.
            let now = Date()
            let index = state.withLock { $0.log.open(at: now, lastBufferAt: $0.lastBufferAt) }
            do {
                try attach(voiceProcessing: false, reusingFile: true)
                noteRestart(index)
            } catch {
                FileHandle.standardError.write(Data(
                    "mic raw fallback failed: \(error) — retrying in 2s\n".utf8
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.restartCapture()
                }
            }
            return
        }

        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attachWithFallbacks(voiceProcessing: false, reusingFile: false)
        } catch {
            // The watchdog reports a track with no file as stalled, so this
            // reaches the person as well as the log.
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
