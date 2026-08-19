import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Transcribing a session again, from the command line, once its two tracks
/// have become one stereo archive.
///
/// The interesting part is that a settled session has no per-track audio left
/// at all: `audio.m4a` is the whole recording, mic on the left and the far end
/// on the right, and a per-track engine has to be handed the channels back one
/// at a time. The rest is about refusing clearly — a folder whose audio was
/// discarded on purpose cannot be transcribed again, and saying so is the
/// entire feature there.
struct RetranscriptionTests {
    /// An engine that recognizes nothing and remembers what it was given. What
    /// it was given is the point: one mono file per speaker means the channels
    /// were pulled out of the archive rather than the stereo file being read
    /// twice.
    private actor RecordingEngine: TranscriptionEngine {
        struct Heard {
            let channels: AVAudioChannelCount
            let seconds: Double
        }

        nonisolated let name = "fake"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput = .perTrack

        private(set) var heard: [Heard] = []
        /// One line per track, deliberately sharing no words: the echo filter
        /// drops mic segments that repeat what the far end said, and this test
        /// is not about the echo filter.
        private let lines = [
            "the microphone side of the conversation",
            "and now the far end answering back",
        ]

        func prepare() async throws {}
        func release() async {}

        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            let file = try AVAudioFile(forReading: audio)
            let format = file.processingFormat
            heard.append(Heard(
                channels: format.channelCount,
                seconds: Double(file.length) / format.sampleRate))
            return [TranscriptSegment(
                start: 0,
                end: 1,
                text: lines[min(heard.count - 1, lines.count - 1)])]
        }
    }

    /// A session as it stands after transcription and settling: one stereo
    /// archive, meta.json pointing both tracks at it, and no transcript —
    /// which is exactly what the recordings window leaves behind when somebody
    /// asks for a re-transcription and then quits the app.
    private static func settledSession(seconds: Double = 2) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-again-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try tone(dir.appendingPathComponent("mic.caf"), seconds: seconds, frequency: 220)
        try tone(dir.appendingPathComponent("system.caf"), seconds: seconds, frequency: 660)
        try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 0],
            "duration_seconds": Int(seconds),
            // Naming and summarizing have already given up on this session, so
            // finishing it reaches for no language model. This test is about
            // the transcript and nothing else.
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ]).write(to: dir.appendingPathComponent("meta.json"))

        TrackCompressor.compress(sessionDir: dir)
        return dir
    }

    private static func tone(_ url: URL, seconds: Double, frequency: Double) throws {
        let rate = 48000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            let count = min(4800, total - written)
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = buffer.floatChannelData![0]
            for i in 0..<count {
                samples[i] = 0.4 * Float(sin(2 * .pi * frequency * Double(written + i) / rate))
            }
            try file.write(from: buffer)
            written += count
        }
    }

    private static let noPostProcessing = PostProcessor.Policy(names: false, summary: false)
    /// And the policy a Mac in ordinary use is under, where both steps are
    /// on. It is what makes a retired recording look outstanding — neither
    /// step has had its turn, because the transcript they read never
    /// arrived — and so what leaves the window's button enabled for one.
    private static let bothSteps = PostProcessor.Policy(names: true, summary: true)

    // MARK: - the route from the command line

    @Test("A settled session is transcribed back out of its stereo archive")
    func settledSessionTranscribesFromTheArchive() async throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm = dir.appendingPathComponent("mic.caf")
        #expect(!FileManager.default.fileExists(atPath: pcm.path))

        let engine = RecordingEngine()
        try await TranscriptionCoordinator(engine: engine).transcribeNow(dir)

        // One call per logical track, each on a mono file the length of the
        // recording: the archive was taken apart, not handed over whole.
        let heard = await engine.heard
        #expect(heard.count == 2)
        #expect(heard.allSatisfy { $0.channels == 1 })
        #expect(heard.allSatisfy { $0.seconds > 1.9 && $0.seconds < 2.2 })

        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.engine == "fake")
        #expect(transcript.segments.map(\.speaker) == ["me", "them"])
        let markdown = try String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("the microphone side of the conversation"))
    }

    /// The bug this whole route exists to fix: `amanu process` used to read a
    /// settled session, report `transcript: pending`, and do nothing at all.
    @Test("A settled session with no transcript is transcribed, not shrugged at")
    func aPendingSettledSessionIsPlannedForTranscription() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        #expect(item.hasAudio)
        #expect(PostProcessor.obstacleToTranscribing(dir) == nil)
        #expect(PostProcessor.plan(for: item, transcriptionEnabled: true)
            == .transcribe(clearingFirst: false))
    }

    @Test("A session whose audio was discarded is refused, and says why")
    func discardedAudioIsRefusedWithAReason() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        TrackCompressor.discard(sessionDir: dir)
        #expect(SessionState.value(dir, "audio_discarded") as? Bool == true)

        #expect(PostProcessor.obstacleToTranscribing(dir) == .audioDiscarded)

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        guard case .refuse(let why) = PostProcessor.plan(
            for: item, again: true, transcriptionEnabled: true
        ) else {
            Issue.record("Expected a session with no audio left to be refused.")
            return
        }
        #expect(why.description.contains("discarded"))
        #expect(why.description.contains("keep_audio"))
    }

    /// Deleted with the Finder rather than by amanu, which reads the same to
    /// everything downstream but not to the person being told about it.
    @Test("A recording that has gone missing is refused as missing")
    func missingAudioIsRefusedAsMissing() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("audio.m4a"))

        #expect(PostProcessor.obstacleToTranscribing(dir) == .audioGone)
        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        #expect(!item.hasAudio)
    }

    @Test("A retired session waits to be asked twice")
    func aRetiredSessionNeedsAgain() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionState.update(dir, with: [
            SessionState.Key.transcriptionFailed: "assemblyai returned no speech",
        ])

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        guard case .refuse(let why) = PostProcessor.plan(for: item, transcriptionEnabled: true)
        else {
            Issue.record("Expected a retired session to be refused without --again.")
            return
        }
        #expect(why.description.contains("no speech"))
        #expect(why.description.contains("--again"))

        #expect(PostProcessor.plan(for: item, again: true, transcriptionEnabled: true)
            == .transcribe(clearingFirst: true))
    }

    @Test("Transcription turned off in the config is said out loud")
    func transcriptionOffIsExplained() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        guard case .refuse(let why) = PostProcessor.plan(for: item, transcriptionEnabled: false)
        else {
            Issue.record("Expected transcription being off to be refused.")
            return
        }
        #expect(why.description.contains("transcription.enabled"))
    }

    /// A transcribed session is left alone: `amanu process` on it is still the
    /// command that names its speakers and summarizes it, and must not throw
    /// away a transcript because it was run twice.
    @Test("A session that already has a transcript is only finished")
    func aTranscribedSessionIsOnlyFinished() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-08-19T09:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")]
        ).write(to: dir)

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        #expect(PostProcessor.plan(for: item, transcriptionEnabled: true) == .finish)
        #expect(PostProcessor.plan(for: item, again: true, transcriptionEnabled: true)
            == .transcribe(clearingFirst: true))
    }

    // MARK: - the same route from the recordings window

    /// The bug the window had after the command line stopped having it: the
    /// button ran the post-processing that needs a transcript, on a session
    /// whose transcript is the thing missing, and said nothing when nothing
    /// came back.
    @Test("Finish processing transcribes a settled recording rather than doing nothing")
    @MainActor
    func theWindowTranscribesASettledRecording() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        #expect(item.isOutstanding, "the button is only offered for a recording that owes work")
        #expect(RecordingsWindow.decision(
            for: item, policy: Self.noPostProcessing, transcriptionEnabled: true)
            == .transcribe(clearingFirst: false))
    }

    /// A retired recording enables the button too, because the names and the
    /// summary it never got still read as outstanding. It is sent to the
    /// button next to it rather than left to press this one for ever.
    @Test("A retired recording is sent to Re-transcribe, in words")
    @MainActor
    func theWindowSendsARetiredRecordingToRetranscribe() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionState.update(dir, with: [
            SessionState.Key.transcriptionFailed: "assemblyai returned no speech",
        ])

        let item = try #require(SessionInventory.item(for: dir, policy: Self.bothSteps))
        #expect(item.isOutstanding)
        guard case .refuse(let why) = RecordingsWindow.decision(
            for: item, policy: Self.bothSteps, transcriptionEnabled: true
        ) else {
            Issue.record("Expected the window to refuse a retired recording.")
            return
        }
        #expect(why.contains("no speech"))
        #expect(why.contains("Re-transcribe"))
        // The window sends nobody to the command line: that flag is not in
        // this window and there is a button here that does the same thing.
        #expect(!why.contains("--again"))
    }

    @Test("A recording whose audio was discarded is refused in the window too")
    @MainActor
    func theWindowRefusesDiscardedAudio() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        TrackCompressor.discard(sessionDir: dir)

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        guard case .refuse(let why) = RecordingsWindow.decision(
            for: item, policy: Self.noPostProcessing, transcriptionEnabled: true
        ) else {
            Issue.record("Expected the window to refuse a recording with no audio left.")
            return
        }
        #expect(why.contains("keep_audio"))
    }

    /// And the answer that is not a refusal at all: there was a transcript,
    /// nothing after it was owed, and the button says so instead of running
    /// for a moment and leaving the window exactly as it was.
    @Test("A recording with nothing left to do says so")
    @MainActor
    func theWindowSaysWhenNothingIsOwed() throws {
        let dir = try Self.settledSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-08-19T09:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")]
        ).write(to: dir)

        let item = try #require(SessionInventory.item(for: dir, policy: Self.noPostProcessing))
        #expect(RecordingsWindow.decision(
            for: item, policy: Self.noPostProcessing, transcriptionEnabled: true)
            == .nothingOwed)
    }
}
