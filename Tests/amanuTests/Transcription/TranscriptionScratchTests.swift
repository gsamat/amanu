import Foundation
import Testing

@testable import amanu

/// What transcribing leaves behind, and when it goes.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false, "keep_audio": true}"#))
struct TranscriptionScratchTests {
    /// The service's answer, as its cache would hold it.
    private static func completed(_ text: String) -> String {
        """
        {"status":"completed","text":"\(text)","utterances":[
          {"speaker":"2A","text":"\(text)","start":100,"end":900}]}
        """
    }

    private static func service(saying text: String) -> StubHTTP {
        StubHTTP { request, _ in
            switch (request.method, request.path) {
            case ("POST", "/v2/upload"):
                return .json(200, #"{"upload_url":"https://cdn.example.test/a"}"#)
            case ("POST", "/v2/transcript"):
                return .json(200, #"{"id":"job-1"}"#)
            default:
                return .json(200, completed(text))
            }
        }
    }

    /// Plant everything an interrupted run could have left.
    private static func plantScratch(in dir: URL) throws -> [URL] {
        let aec = dir.appendingPathComponent(".transcription-aec-v3-0123456789abcdef0123")
        let slices = dir.appendingPathComponent("openai-slices")
        for folder in [aec, slices] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let planted = [
            dir.appendingPathComponent("transcript.assemblyai.multichannel.json"),
            dir.appendingPathComponent("transcript.openai.2.json"),
            dir.appendingPathComponent("transcript.elevenlabs.audio.channel1.json"),
            dir.appendingPathComponent("transcript.assemblyai.0011223344556677.job.json"),
            aec.appendingPathComponent("transcript.openai.8899aabbccddeeff.json"),
            slices.appendingPathComponent("piece-1.m4a"),
        ]
        for file in planted { try Data("the whole meeting".utf8).write(to: file) }
        return planted + [aec, slices]
    }

    @Test("Re-transcribing discards the summary, the names and every cached answer")
    func retranscriptionClearsEverything() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a", state: [
            SessionState.Key.summaryStatus: SessionState.failed,
            SessionState.Key.summaryFailedFor: "an earlier configuration",
            SessionState.Key.speakersStatus: SessionState.failed,
            SessionState.Key.speakersFailedFor: "an earlier configuration",
        ])
        for file in ["transcript.json", "transcript.md", "summary.md", SpeakerNames.file] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(file))
        }
        let planted = try Self.plantScratch(in: dir)

        PostProcessor.markForRetranscription(dir)

        for name in ["transcript.json", "transcript.md", SpeakerNames.file] {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                    "\(name) survived")
        }
        // Kept until a new summary replaces it, but no longer this session's.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(!PostProcessor.hasCurrentSummary(dir))
        for url in planted {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) survived")
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        let meta = try #require(SessionState.read(dir))
        for key in [
            SessionState.Key.summaryStatus, SessionState.Key.summaryFailedFor,
            SessionState.Key.speakersStatus, SessionState.Key.speakersFailedFor,
        ] {
            #expect(meta[key] == nil, "\(key) survived")
        }
    }

    @Test("A second transcription asks the service again rather than reading back the first")
    func retranscriptionGetsTheNewAnswer() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        TrackCompressor.compress(sessionDir: dir)
        let archive = dir.appendingPathComponent("audio.m4a")
        let stale = try AssemblyAIEngine(apiKey: "test-key")
        try Data(Self.completed("what the old model heard").utf8)
            .write(to: await stale.cacheURL(for: archive, multichannel: true))

        PostProcessor.markForRetranscription(dir)
        let service = Self.service(saying: "what the new model heard")
        let engine = try AssemblyAIEngine(apiKey: "test-key", session: service.session)
        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.text) == ["what the new model heard"])
        #expect(service.requests(to: "/v2/upload").count == 2)
    }

    @Test("A finished transcription leaves no cached answer and no echo folder behind")
    func transcriptRemovesScratch() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let planted = try Self.plantScratch(in: dir)
        let service = Self.service(saying: "hello")
        let engine = try AssemblyAIEngine(apiKey: "test-key", session: service.session)

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(PostProcessor.readTranscript(dir) != nil)
        #expect(TranscriptionScratch.items(in: dir).isEmpty)
        for url in planted {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) survived")
        }
    }

    @Test("A retired session keeps its audio but not the cached answers")
    func retirementRemovesScratch() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        _ = try Self.plantScratch(in: dir)
        struct Refused: TranscriptionFailure { var isPermanent: Bool { true } }

        await #expect(throws: Refused.self) {
            try await TranscriptionCoordinator(
                engine: FakeEngine("parakeet", answer: { _, _ in throw Refused() }), onStop: { nil }
            ).transcribeNow(dir)
        }

        #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir))
        #expect(TranscriptionScratch.items(in: dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path))
    }
}
