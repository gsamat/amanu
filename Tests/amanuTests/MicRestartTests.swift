import AVFoundation
import Foundation
import os.lock
import Testing

@testable import amanu

/// The bookkeeping around a mid-session capture restart. The capture itself
/// needs a real device and a real route change, so what is covered here is the
/// arithmetic that decides where the audio after a restart lands on the wall
/// clock, and the record left behind for the person reading meta.json a day
/// later.
struct MicRestartTests {
    @Test("Capture metadata distinguishes requested processing from what ran")
    func captureMetadataRecordsTheExperiment() throws {
        let capture = MicRecorder.Capture(
            requestedVoiceProcessing: true,
            initialVoiceProcessing: true,
            finalVoiceProcessing: false,
            inputDevice: "MacBook Air Microphone",
            outputDevice: "MacBook Air Speakers",
            sampleRate: 48_000,
            channels: 1,
            sampleFormat: "float32")

        let meta = capture.meta
        #expect(meta["requested_voice_processing"] as? Bool == true)
        #expect(meta["initial_voice_processing"] as? Bool == true)
        #expect(meta["final_voice_processing"] as? Bool == false)
        #expect(meta["fell_back_to_raw"] as? Bool == true)
        #expect(meta["input_device"] as? String == "MacBook Air Microphone")
        #expect(meta["output_device"] as? String == "MacBook Air Speakers")
        #expect(meta["sample_rate_hz"] as? Int == 48_000)
        #expect(meta["channels"] as? Int == 1)
        #expect(meta["sample_format"] as? String == "float32")
        #expect(JSONSerialization.isValidJSONObject(meta))
    }

    @Test func aGapWorthPaddingBecomesFrames() {
        #expect(MicRecorder.silenceFrames(gap: 0.5, sampleRate: 48000) == 24000)
        #expect(MicRecorder.silenceFrames(gap: 1.72, sampleRate: 16000) == 27520)
    }

    /// The threshold is what keeps ordinary buffer jitter from being written
    /// into the track as silence, one restart at a time.
    @Test func aGapTooShortToBeRealIsIgnored() {
        #expect(MicRecorder.silenceFrames(gap: 0.05, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: 0, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: -0.3, sampleRate: 48000) == 0)
    }

    @Test func aRestartRecordsBothSidesOfTheRouteChange() {
        let iso = ISO8601DateFormatter()
        let at = Date(timeIntervalSince1970: 1_755_710_180)
        var restart = MicRecorder.Restart(
            at: at,
            voiceProcessing: true,
            inputWas: "AirPods Pro", inputNow: "MacBook Pro Microphone",
            outputWas: "AirPods Pro", outputNow: "MacBook Pro Speakers"
        )
        restart.gapMs = 470

        let meta = restart.meta(iso: iso)
        #expect(meta["at"] as? String == iso.string(from: at))
        #expect(meta["gap_ms"] as? Int == 470)
        #expect(meta["voice_processing"] as? Bool == true)
        #expect(meta["input_was"] as? String == "AirPods Pro")
        #expect(meta["input_now"] as? String == "MacBook Pro Microphone")
        #expect(meta["output_was"] as? String == "AirPods Pro")
        #expect(meta["output_now"] as? String == "MacBook Pro Speakers")
    }

    /// A restart whose gap is still open, or that happened where no device
    /// would name itself, says less rather than saying nothing — and never
    /// puts nulls in meta.json.
    @Test func unknownFieldsAreLeftOutRatherThanWrittenNull() throws {
        let restart = MicRecorder.Restart(at: Date())
        let meta = restart.meta(iso: ISO8601DateFormatter())
        #expect(meta.count == 1)
        #expect(meta["at"] != nil)
        #expect(JSONSerialization.isValidJSONObject(meta))
    }

    // MARK: - which restart a gap belongs to

    /// The first buffer of a new engine can land before the restart that
    /// built it has been written up. The entry used to be appended only
    /// then, so that buffer's gap went onto the previous restart.
    @Test("A gap closed before its restart is written up still lands on that restart")
    func gapLandsOnItsOwnRestart() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()

        let first = log.open(at: t, lastBufferAt: t)
        _ = log.close(now: t.addingTimeInterval(1.5), carried: 0)
        log.update(first) { $0.inputNow = "AirPods" }

        let second = log.open(at: t.addingTimeInterval(60), lastBufferAt: t.addingTimeInterval(60))
        // The new engine's first buffer, before the restart is written up.
        let gap = log.close(now: t.addingTimeInterval(60.4), carried: 0.1)
        log.update(second) { $0.inputNow = "MacBook Pro Microphone" }

        #expect(abs((gap ?? 0) - 0.3) < 0.001)
        #expect(log.entries.map(\.gapMs) == [1500, 300])
        #expect(log.entries.map(\.inputNow) == ["AirPods", "MacBook Pro Microphone"])
    }

    @Test("A restart that fails and retries is one gap, measured from the first attempt")
    func retriesAreOneGap() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()
        let first = log.open(at: t, lastBufferAt: t)
        let again = log.open(at: t.addingTimeInterval(2), lastBufferAt: t)
        #expect(first == again)
        #expect(log.entries.count == 1)
        #expect(log.close(now: t.addingTimeInterval(4), carried: 0) == 4)
        #expect(log.recent(within: 30, of: t.addingTimeInterval(5)) == 1)
    }

    @Test("The storm guard does not count the restart under way")
    func stormCountExcludesTheOpenRestart() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()
        log.open(at: t, lastBufferAt: t)
        #expect(log.recent(within: 30, of: t) == 0)
    }

    // MARK: - microphones that refuse

    /// A call app on a microphone that will not let us record it used to be
    /// chased every fifteen seconds: restart, refusal, fall back to the
    /// default, and the next route check found the same device again.
    @Test("A microphone that refused is not followed again until its wait is over")
    func refusedMicrophoneIsNotChased() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let zoomMic: AudioObjectID = 71, builtIn: AudioObjectID = 42
        var refused = MicRecorder.RefusedDevices()

        #expect(MicRecorder.routeTarget(wanted: zoomMic, fallback: builtIn, refused: refused, now: t)
                == zoomMic)
        refused.refuse(zoomMic, at: t)
        for tick in stride(from: 15.0, to: 60, by: 15) {
            #expect(MicRecorder.routeTarget(
                wanted: zoomMic, fallback: builtIn, refused: refused, now: t.addingTimeInterval(tick))
                    == builtIn)
        }
        #expect(MicRecorder.routeTarget(
            wanted: zoomMic, fallback: builtIn, refused: refused, now: t.addingTimeInterval(61))
                == zoomMic)

        // Refused again: twice as long before the next try.
        refused.refuse(zoomMic, at: t.addingTimeInterval(61))
        #expect(refused.isRefused(zoomMic, at: t.addingTimeInterval(61 + 119)))
        #expect(!refused.isRefused(zoomMic, at: t.addingTimeInterval(61 + 121)))
        #expect(MicRecorder.RefusedDevices.wait(afterRefusals: 20) == 15 * 60)
    }

    // MARK: - bringing capture up

    struct Refused: Error {}

    /// At the start of a session a single refusal used to fail the whole
    /// recording, system track included, while the same refusal mid-session
    /// already fell back.
    @Test("A chosen microphone that refuses gives way to the default, voice processing still on")
    func chosenDeviceGivesWayFirst() throws {
        var attempts: [Bool] = []
        var chosen = true
        try MicRecorder.attachWithFallbacks(
            voiceProcessing: true,
            attempt: { voice in
                attempts.append(voice)
                if chosen { chosen = false; throw Refused() }
            },
            failedOnChosenDevice: { attempts.count == 1 })
        #expect(attempts == [true, true])
    }

    @Test("Voice processing that will not start gives way to raw capture")
    func voiceGivesWayToRaw() throws {
        var attempts: [Bool] = []
        try MicRecorder.attachWithFallbacks(
            voiceProcessing: true,
            attempt: { voice in
                attempts.append(voice)
                if voice { throw Refused() }
            },
            failedOnChosenDevice: { false })
        #expect(attempts == [true, false])
    }

    @Test("Capture that will not start any way at all is an error")
    func nothingWorksThrows() {
        var attempts: [Bool] = []
        #expect(throws: Refused.self) {
            try MicRecorder.attachWithFallbacks(
                voiceProcessing: false,
                attempt: { voice in attempts.append(voice); throw Refused() },
                failedOnChosenDevice: { false })
        }
        #expect(attempts == [false])
    }

    // MARK: - the main thread during a route change

    /// The shape of 10 November 2026, without the device. The main thread is
    /// waiting for the engine's queue, as it does inside `engine.stop()` and
    /// the engine's `dealloc`, while that queue posts the configuration
    /// change. Observed on the main operation queue, the post waits for the
    /// main thread in turn and neither moves again; here that shows as the
    /// wait timing out instead of as a test that never ends.
    @Test("A configuration change posted while the main thread waits for the poster is not a deadlock")
    func configurationChangeDoesNotWaitForTheMainThread() async {
        let center = NotificationCenter()
        let delivered = DispatchSemaphore(value: 0)
        let deliveredOnMain = OSAllocatedUnfairLock(initialState: [Bool]())
        let token = MicRecorder.observeConfigurationChanges(in: center) { _ in
            deliveredOnMain.withLock { $0.append(pthread_main_np() != 0) }
            delivered.signal()
        }
        defer { center.removeObserver(token) }

        let engineQueue = DispatchQueue(label: "amanu.tests.engine")
        let posted = DispatchSemaphore(value: 0)
        let postReturned: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                engineQueue.async {
                    center.post(name: .AVAudioEngineConfigurationChange, object: nil)
                    posted.signal()
                }
                continuation.resume(returning: posted.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(postReturned, "the post waited for the main thread, which was waiting for it")

        // Not waiting is half of it; the change still has to arrive, and on
        // the main thread, where everything that acts on it lives.
        let arrived: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: delivered.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(arrived)
        #expect(deliveredOnMain.withLock { $0 } == [true])
    }

    @Test("The observer says which engine posted without keeping it alive")
    func configurationChangeCarriesAnIdentityNotAReference() async {
        final class Poster {
            let gone: OSAllocatedUnfairLock<Bool>
            init(gone: OSAllocatedUnfairLock<Bool>) { self.gone = gone }
            deinit { gone.withLock { $0 = true } }
        }
        let gone = OSAllocatedUnfairLock(initialState: false)
        let center = NotificationCenter()
        let seen = OSAllocatedUnfairLock(initialState: [ObjectIdentifier?]())
        let delivered = DispatchSemaphore(value: 0)
        let token = MicRecorder.observeConfigurationChanges(in: center) { poster in
            seen.withLock { $0.append(poster) }
            delivered.signal()
        }
        defer { center.removeObserver(token) }

        var poster: Poster? = Poster(gone: gone)
        let identity = ObjectIdentifier(poster!)
        center.post(name: .AVAudioEngineConfigurationChange, object: poster)
        poster = nil
        #expect(gone.withLock { $0 })

        let arrived: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: delivered.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(arrived)
        #expect(seen.withLock { $0 } == [identity])
    }

    /// `-[AVAudioEngine dealloc]` waits for the engine's queue, so where the
    /// last reference is dropped is where the wait happens.
    @Test("An engine that has been replaced is let go off the thread that replaced it")
    @MainActor
    func aRetiredEngineIsReleasedElsewhere() async {
        final class Probe: @unchecked Sendable {
            let onDeinit: @Sendable (Bool) -> Void
            init(onDeinit: @escaping @Sendable (Bool) -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit(pthread_main_np() != 0) }
        }
        let releasedOnMain: Bool = await withCheckedContinuation { continuation in
            var probe: Probe? = Probe { continuation.resume(returning: $0) }
            let retiring = MicRecorder.Retiring(probe!)
            probe = nil
            retiring.release()
        }
        #expect(!releasedOnMain)
    }

    /// The wait for the old engine keeps teardown ahead of setup. It must not
    /// become the hang it replaced.
    @Test("An engine that will not go away holds its replacement up only so long")
    func aStuckEngineIsNotWaitedForForever() {
        final class Stuck: @unchecked Sendable {
            let letGo: DispatchSemaphore
            init(letGo: DispatchSemaphore) { self.letGo = letGo }
            deinit { letGo.wait() }
        }
        let letGo = DispatchSemaphore(value: 0)
        defer { letGo.signal() }
        var stuck: Stuck? = Stuck(letGo: letGo)
        let retiring = MicRecorder.Retiring(stuck!)
        stuck = nil

        let began = Date()
        let gone = retiring.release(waitingUpTo: 0.2)
        #expect(!gone)
        #expect(Date().timeIntervalSince(began) < 2)

        // And one that does go away is waited for, so the order holds.
        final class Plain {}
        #expect(MicRecorder.Retiring(Plain()).release(waitingUpTo: 5))
    }

    // MARK: - writing after a gap

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func constant(_ value: Float, frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(repeating: value, count: frames)
        return buffer
    }

    /// The silence for a gap is written off the capture callback, and the
    /// audio that follows it must still come after it, in order.
    @Test("Audio after a gap reaches the file after its silence, in order")
    func writerKeepsOrderAcrossAGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormats.pcmSettings(sampleRate: 8_000, channels: 1),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let writer = TrackWriter(file: file, label: "test")
            writer.write(constant(0.5, frames: 100, format: format))
            writer.write(constant(0.25, frames: 100, format: format), after: 20_000)
            for _ in 0..<5 { writer.write(constant(0.125, frames: 100, format: format)) }
            writer.drain()
        }

        let samples = try readSamples(url)
        #expect(samples.count == 100 + 20_000 + 100 + 500)
        #expect(samples[0..<100].allSatisfy { abs($0 - 0.5) < 0.001 })
        #expect(samples[100..<20_100].allSatisfy { $0 == 0 })
        #expect(samples[20_100..<20_200].allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(samples[20_200...].allSatisfy { abs($0 - 0.125) < 0.001 })
    }

    @Test("A restart's meta says how much of a very long gap was padded")
    func paddedShortOfTheGapIsRecorded() {
        var restart = MicRecorder.Restart(at: Date())
        restart.gapMs = 3_600_000
        restart.paddedMs = Int(MicRecorder.longestPad * 1000)
        let meta = restart.meta(iso: ISO8601DateFormatter())
        #expect(meta["gap_ms"] as? Int == 3_600_000)
        #expect(meta["padded_ms"] as? Int == 600_000)
    }
}
