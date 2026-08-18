import AVFoundation
import CoreAudio
import Foundation
import os.lock

/// Records system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes the
/// chosen processes' output to stereo and hands us buffers through a private
/// aggregate device. First use triggers the one-time "System Audio Recording"
/// TCC prompt and lights the purple recording indicator while active.
final class SystemAudioRecorder {
    /// Whose output lands on the far-end track.
    enum Scope: Equatable {
        /// Everything the Mac plays. Safe and indiscriminate: notification
        /// dings, music and the video you opened afterwards all count as "the
        /// meeting", both in the transcript and in the auto-record loop's
        /// judgement of whether anyone is still talking.
        case everything
        /// Only processes belonging to these bundle-id families — the call
        /// app. Cleaner recordings, and a far-end silence signal that means
        /// what it says.
        case apps([String])
    }

    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            }
        }
    }

    private(set) var scope: Scope = .everything
    /// The audio objects currently in the tap. Compared on refresh so a tap is
    /// only rewritten when the app's set of processes has actually changed.
    private var tappedObjects: [AudioObjectID] = []
    private var refreshFailed = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "me.samat.amanu.system-tap")
    private let liveAudio = LiveAudioBufferRelay()
    private(set) var isRecording = false

    // Thread-safe shared state: accessed from both the main thread and the
    // IOProc callback (background serial queue) without further sync.
    private struct LockedState {
        var file: AVAudioFile?
        var firstBufferAt: Date?
        var lastSoundAt: Date?
        var levelMeasurable = true
        var muted = false
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    /// Wall-clock time of the last buffer louder than the noise floor — the
    /// far end saying something. nil means nothing audible yet.
    var lastSoundAt: Date? { state.withLock { $0.lastSoundAt } }

    /// False once a buffer arrived in a sample format we can't measure.
    var levelMeasurable: Bool { state.withLock { $0.levelMeasurable } }

    /// While muted the tap keeps running and silence is written instead of the
    /// audio, so the track stays wall-clock aligned across a pause.
    var isMuted: Bool {
        get { state.withLock { $0.muted } }
        set { state.withLock { $0.muted = newValue } }
    }

    private var file: AVAudioFile? {
        get { state.withLock { $0.file } }
        set { state.withLock { $0.file = newValue } }
    }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date? {
        get { state.withLock { $0.firstBufferAt } }
        set { state.withLock { $0.firstBufferAt = newValue } }
    }

    /// Start capturing system audio, encoding AAC into `url` (use a .caf
    /// extension — CAF needs no finalization pass, so a crash mid-meeting
    /// loses nothing already written).
    func start(writingTo url: URL, scope: Scope = .everything) throws {
        guard !isRecording else { return }

        let (description, objects) = Self.describe(scope)
        self.scope = objects.isEmpty ? .everything : scope
        tappedObjects = objects

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            file = try makeFile(url: url, format: format)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        cleanup()
        liveAudio.install(nil)
    }

    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {
        liveAudio.install(sink)
    }

    func setLiveAudioPaused(_ paused: Bool) {
        liveAudio.isPaused = paused
    }

    /// Re-point the tap at the app's processes as they come and go — a
    /// browser renderer restarted by a reloaded tab, a helper the call app
    /// spawns when someone shares their screen, or a second call app joining
    /// the session. Cheap enough for the 15-second liveness tick.
    ///
    /// The tap's description is settable, so this never touches the aggregate
    /// device or the file — nothing about the recording is interrupted. If the
    /// system refuses, the existing tap keeps running and we say so once
    /// rather than every fifteen seconds for an hour.
    func refresh(scope newScope: Scope) {
        guard isRecording, tapID != kAudioObjectUnknown else { return }
        guard case .apps = newScope else { return }

        let (description, objects) = Self.describe(newScope)
        guard !objects.isEmpty, objects != tappedObjects else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = description
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(
                tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer
            )
        }
        guard status == noErr else {
            if !refreshFailed {
                refreshFailed = true
                FileHandle.standardError.write(Data(
                    ("system tap: can't update the tapped processes (OSStatus \(status)) — "
                        + "keeping the ones it started with\n").utf8
                ))
            }
            return
        }
        tappedObjects = objects
        scope = newScope
        FileHandle.standardError.write(Data(
            "system tap: now following \(objects.count) process(es)\n".utf8
        ))
    }

    // MARK: -

    /// Build a tap description for a scope, plus the audio objects it covers.
    /// An app scope that matches no running process comes back as a global tap
    /// — recording everything is wrong in a small way, recording nothing is
    /// wrong in the way that loses the meeting.
    private static func describe(_ scope: Scope) -> (CATapDescription, [AudioObjectID]) {
        var objects: [AudioObjectID] = []
        var bundleIDs: [String] = []
        if case .apps(let families) = scope {
            let processes = AudioProcesses.matching(families: families)
            objects = processes.map(\.object)
            bundleIDs = Array(Set(processes.map(\.bundleID))).sorted()
            if objects.isEmpty {
                FileHandle.standardError.write(Data(
                    ("system tap: nothing running for \(families.joined(separator: ", ")) — "
                        + "recording all system audio instead\n").utf8
                ))
            }
        }

        let description = objects.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "amanu system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        if !objects.isEmpty, #available(macOS 26.0, *) {
            // Ask the system to keep following these apps across restarts: a
            // call app that relaunches mid-meeting otherwise drops out of the
            // tap silently, and a silent far-end track is the failure this
            // program exists to avoid.
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return (description, objects)
    }

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "amanu-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: AudioFormats.pcmSettings(
                    sampleRate: format.sampleRate, channels: format.channelCount
                ),
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            self.writeTracked(buffer, to: file)
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    /// Write one tapped buffer, tracking its level on the way through and
    /// substituting silence while paused.
    private func writeTracked(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile) {
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
            // The tap's buffer is Core Audio's memory, borrowed no-copy — the
            // silence has to be written into a buffer of our own.
            guard let silent = AudioLevel.silence(like: buffer) else { return }
            outgoing = silent
        }
        do {
            try file.write(from: outgoing)
            liveAudio.forward(outgoing)
        } catch {
            FileHandle.standardError.write(Data("system track write failed: \(error)\n".utf8))
        }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
    }
}
