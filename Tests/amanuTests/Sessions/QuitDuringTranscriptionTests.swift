import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Quitting while the queue is transcribing.
///
/// This is not an edge case: the queue is fed by every finished recording, so a
/// quit lands mid-inference all the time. Ending the process while whisper is
/// still inside `whisper_full` runs whisper's static teardown underneath a live
/// inference, which aborts in `ggml_metal_rsets_free` and hands the person a
/// crash dialog for a quit they asked for (.issues/011).
///
/// So the queue stops with the quit, and what it must not do on the way out is
/// leave marks that would cost the session: an attempt counted against it, a
/// claim still held, or compressed audio under a transcript that was never
/// written. The session stays pending, and the scan at the next launch offers it
/// again.
struct QuitDuringTranscriptionTests {
    @Test("A quit mid-transcription stops the queue without counting a failure")
    func stoppingTheQueueIsNotAFailure() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session(in: root)
        let engine = SleepingEngine()
        let queue = TranscriptionCoordinator(engine: engine, onStop: { nil }, enabled: { true })

        await queue.enqueue(dir)
        try await Self.waitUntil { await queue.isTranscribing }

        await queue.stopForTermination()

        let stillTranscribing = await queue.isTranscribing
        #expect(!stillTranscribing)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
        // The marks that would make one quit expensive: a session counting
        // toward the three attempts it gets, a verdict of failure, an audio
        // track compressed because a transcript was assumed to exist.
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("mic.caf").path))
        // Whisper's context is released here rather than left for exit() to run
        // its destructors over, which is the other half of the same guarantee.
        #expect(await engine.released)
        // Giving the folder back is what keeps the next launch's scan able to
        // find it: a claim left behind hides the session from every queue. By
        // name, because the scan resolves the temporary directory's /var
        // symlink and the URL it returns is not spelled the way this one is.
        #expect(!SessionClaim.isHeld(dir))
        #expect(TranscriptionCoordinator.pendingSessions(in: root).map(\.lastPathComponent)
            == [dir.lastPathComponent])
    }

    /// A cloud engine reports the same cancel in its own dialect — URLSession
    /// cancels an upload with `URLError.cancelled`, not with a
    /// `CancellationError`. Which engine was running must not decide whether the
    /// quit looks like a failure.
    @Test("A cancelled cloud upload is a quit too, whatever error it arrives as")
    func anotherEnginesCancellationIsAlsoAQuit() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session(in: root)
        let queue = TranscriptionCoordinator(
            engine: CancelledUploadEngine(), onStop: { nil }, enabled: { true })

        await queue.enqueue(dir)
        try await Self.waitUntil { await queue.isTranscribing }

        await queue.stopForTermination()

        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
    }

    /// The order the two arrive in on the SIGTERM path: the quit is prepared
    /// first, and only then does the closing session get handed to the queue.
    /// Starting that one would put a fresh inference under `exit()` — the same
    /// crash, one step later.
    @Test("An enqueue that arrives after the quit starts nothing")
    func theQueueStaysStopped() async throws {
        let root = try Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session(in: root)
        let engine = SleepingEngine()
        let queue = TranscriptionCoordinator(engine: engine, onStop: { nil }, enabled: { true })

        await queue.stopForTermination()
        await queue.enqueue(dir)
        await queue.resumePending(root: root)

        // The same chance the queue gets in a live run, and then some.
        try await Task.sleep(for: .milliseconds(50))

        let started = await engine.starts
        let stillTranscribing = await queue.isTranscribing
        #expect(started == 0)
        #expect(!stillTranscribing)
    }

    /// An engine that never finishes, like whisper mid-inference: it returns
    /// when the task is cancelled and says so with a `CancellationError`.
    private actor SleepingEngine: TranscriptionEngine {
        nonisolated let name = "sleeping"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput = .perTrack

        private(set) var starts = 0
        private(set) var released = false

        func prepare() async throws {}
        func release() async { released = true }

        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            starts += 1
            try await Task.sleep(for: .seconds(60))
            return [.init(start: 0, end: 1, text: "never reached")]
        }
    }

    private actor CancelledUploadEngine: TranscriptionEngine {
        nonisolated let name = "assemblyai-test"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput = .multichannel

        func prepare() async throws {}
        func release() async {}

        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                throw URLError(.cancelled)
            }
            return []
        }
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NeverStarted()
    }

    private struct NeverStarted: Error {}

    /// A recordings root of its own, so the pending-session scan in the test
    /// sees this session and nothing else.
    private static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A session as `stopSession` leaves one behind: meta.json and two tracks,
    /// no transcript. The audio is a second of silence, because the engines here
    /// are about being interrupted rather than about hearing anything.
    private static func session(in root: URL) throws -> URL {
        let dir = root.appendingPathComponent("2026-09-16 19-49", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try silence(dir.appendingPathComponent("mic.caf"))
        try silence(dir.appendingPathComponent("system.caf"))
        try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 0],
            "duration_seconds": 1,
            // Naming and summarizing have already given up on this session, so
            // finishing it reaches for no language model.
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private static func silence(_ url: URL) throws {
        let rate = 16000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
    }
}
