import Foundation
import Testing

@testable import amanu

/// What a failure costs a session: an attempt, its place in the queue, or —
/// when the fault is the machine's — nothing.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct TranscriptionFailureTests {
    private struct Flaky: Error, CustomStringConvertible {
        var description: String { "the recognizer fell over" }
    }

    private struct Refused: TranscriptionFailure {
        var isPermanent: Bool { true }
    }

    private static func attempts(_ dir: URL) -> Int? {
        SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int
    }

    @Test("A failing session is counted each time and retired on the third")
    func retiredAfterThreeAttempts() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Flaky() })

        for expected in 1...2 {
            await #expect(throws: Flaky.self) {
                try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
            }
            #expect(Self.attempts(dir) == expected)
            #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
                .map(\.lastPathComponent) == [dir.lastPathComponent])
        }
        await #expect(throws: Flaky.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == 3)
        #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir))
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).isEmpty)
    }

    @Test("A permanent failure retires the session on the first attempt")
    func permanentRetiresAtOnce() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Refused() })

        await #expect(throws: Refused.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == 1)
        #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    /// The retired session's tracks are compressed after the failed
    /// transcription has let go of its claim — and used to be compressed
    /// without one, under whoever had picked the folder up in the meantime.
    @Test("A retired session is compressed only under its own claim")
    func retirementCompressesUnderTheClaim() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let held = try recordings.session("2026-09-28-a")
        let free = try recordings.session("2026-09-28-b")
        try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started": "2026-09-28T09:00:00Z", "stage": "transcribe",
        ]).write(to: SessionClaim.url(held))

        #expect(TranscriptionFailurePolicy.record(Refused(), for: held, engine: nil) == .retired)
        #expect(TranscriptionFailurePolicy.record(Refused(), for: free, engine: nil) == .retired)

        #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent("mic.caf").path),
                "the tracks were compressed under somebody else's claim")
        #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent("audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: free.appendingPathComponent("audio.m4a").path))
        #expect(!SessionClaim.isHeld(free))
    }

    /// A model that would not download used to fail every meeting in the
    /// queue once each, restart the download from nothing for each of them,
    /// and retire all of them on the third launch.
    @Test("A model that will not prepare is tried once per drain and counted against nobody")
    func preparationFailureIsNotCounted() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "whisper"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let sessions = try ["2026-09-28-a", "2026-09-28-b", "2026-09-28-c"].map {
            try recordings.session($0)
        }
        let whisper = FakeEngine("whisper", prepareError: { URLError(.networkConnectionLost) })

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { _ in whisper })), onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(whisper.counts.prepared == 1)
        for dir in sessions {
            #expect(Self.attempts(dir) == nil)
            #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
        }
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
            .map(\.lastPathComponent) == sessions.map(\.lastPathComponent))
    }

    @Test("Sessions held back by the machine are offered again with the next recording")
    func heldBackSessionsReturn() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "whisper"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let early = try recordings.session("2026-09-28-a")
        let downloads = Flag()
        let whisper = FakeEngine("whisper", prepareError: {
            if downloads.isRaised { return nil }
            downloads.raise()
            return URLError(.networkConnectionLost)
        })
        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { _ in whisper })), onStop: { nil })
        await coordinator.drainPending(in: recordings.root)
        #expect(PostProcessor.readTranscript(early) == nil)

        let later = try recordings.session("2026-09-28-b")
        await coordinator.drainPending(in: recordings.root)

        #expect(PostProcessor.readTranscript(early)?.engine == "whisper")
        #expect(PostProcessor.readTranscript(later)?.engine == "whisper")
    }

    @Test("No network under an explicit cloud engine is not the recording's fault")
    func offlineIsNotCounted() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "assemblyai"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let cloud = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw URLError(.notConnectedToInternet)
        })

        for _ in 1...4 {
            await #expect(throws: URLError.self) {
                try await TranscriptionCoordinator(
                    engines: EngineResolver(environment: .fake(cloud: { _ in cloud })),
                    onStop: { nil }
                ).transcribeNow(dir)
            }
        }
        #expect(Self.attempts(dir) == nil)
        #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    @Test("A refused key keeps the recording's attempts")
    func refusedKeyIsNotCounted() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw CloudHTTP.Failure.unauthorized(
                service: "assemblyai", what: "upload", status: 401, body: "")
        })

        await #expect(throws: CloudHTTP.Failure.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == nil)
    }

    @Test("Fish key and credit failures on a later channel leave the recording pending",
          arguments: [401, 403, 402])
    func fishAccountFailuresDoNotRetireSession(status: Int) async throws {
        try await withFreshHome(config: Self.fishConfig) { _ in
            let recordings = try TestRecordings()
            defer { recordings.remove() }
            let dir = try recordings.session("2026-10-02-fish")
            let stub = StubHTTP { _, count in
                count == 1 ? .json(200, Self.fishSpeech("Mic sentence.")) : .json(status, "account refused")
            }
            let engine = try FishAudioEngine(apiKey: "fish-test", session: stub.session)
            let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })

            // Environmental trouble must not consume the retry allowance,
            // even after more attempts than would retire a failing recording.
            for _ in 0..<4 {
                let error = await #expect(throws: CloudHTTP.Failure.self) {
                    try await coordinator.transcribeNow(dir)
                }
                #expect(error?.status == status)
                #expect(error?.isEnvironmental == true)
                #expect(Self.attempts(dir) == nil)
                #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
                #expect(SessionState.value(dir, SessionState.Key.transcriptionDeferred) as? Bool == true)
                #expect(PostProcessor.readTranscript(dir) == nil)
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
                #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
                #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(
                    TranscriptionScratch.fishAudioSliceFolder, isDirectory: true).path))
                #expect(!SessionClaim.isHeld(dir))
            }
            #expect(stub.requests.count == 5, "the completed mic response must not be paid for again")
            #expect(ProviderCache.files(in: dir).count == 1)
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
                .map(\.lastPathComponent) == [dir.lastPathComponent])
        }
    }

    @Test("A missing Fish key does not spend an attempt or touch the session audio")
    func missingFishKeyDoesNotRetireSession() async throws {
        try await withFreshHome(config: Self.fishConfig) { _ in
            let recordings = try TestRecordings()
            defer { recordings.remove() }
            let dir = try recordings.session("2026-10-02-fish")
            let stub = StubHTTP { _, _ in .json(200, Self.fishSpeech("Unexpected upload.")) }
            let resolver = EngineResolver(environment: .fake(cloud: { _ in
                try FishAudioEngine(session: stub.session)
            }))
            let coordinator = TranscriptionCoordinator(engines: resolver, onStop: { nil })

            let error = await #expect(throws: FishAudioEngine.EngineError.self) {
                try await coordinator.transcribeNow(dir)
            }

            guard case .noAPIKey = error else {
                Issue.record("expected missing Fish key, got \(String(describing: error))")
                return
            }
            #expect(Self.attempts(dir) == nil)
            #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
                .map(\.lastPathComponent) == [dir.lastPathComponent])
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
            #expect(PostProcessor.readTranscript(dir) == nil)
            #expect(stub.requests.isEmpty)
        }
    }

    @Test("A failed later Fish piece publishes nothing and resumes from the completed cache")
    func fishLaterPieceResumesWithoutPartialPublication() async throws {
        try await withFreshHome(config: Self.fishConfig) { _ in
            let recordings = try TestRecordings()
            defer { recordings.remove() }
            let dir = recordings.root.appendingPathComponent("2026-10-02-import", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let audio = dir.appendingPathComponent("source.wav")
            try TestAudio.writeTone(to: audio, seconds: 5, frequency: 440, sampleRate: 48_000)
            try JSONSerialization.data(withJSONObject: [
                "files": ["source": "source.wav"],
                "start_offset_ms": ["source": 0],
                "trigger": "import",
                "duration_seconds": 5,
                SessionState.Key.speakersStatus: "failed",
                SessionState.Key.summaryStatus: "failed",
            ]).write(to: dir.appendingPathComponent("meta.json"))
            let stub = StubHTTP { _, count in
                switch count {
                case 1: return .json(200, Self.fishSpeech("Piece one."))
                case 2: return .json(503, "temporarily busy")
                case 3: return .json(200, Self.fishSpeech("Piece two."))
                default: return .json(200, Self.fishSpeech("Piece three."))
                }
            }
            let engine = try FishAudioEngine(
                apiKey: "fish-test", session: stub.session, maxPieceDuration: 2, retry: .once)
            let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })

            let error = await #expect(throws: CloudHTTP.Failure.self) {
                try await coordinator.transcribeNow(dir)
            }
            #expect(error?.status == 503)
            #expect(Self.attempts(dir) == 1)
            #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
            #expect(PostProcessor.readTranscript(dir) == nil)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
            #expect(FileManager.default.fileExists(atPath: audio.path))
            let firstCache = await engine.cacheURL(for: audio, channel: nil, piece: 0, of: 3)
            #expect(FileManager.default.fileExists(atPath: firstCache.path))
            #expect(ProviderCache.files(in: dir).count == 1)
            #expect(stub.requests.count == 2)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(
                TranscriptionScratch.fishAudioSliceFolder, isDirectory: true).path))
            #expect(!SessionClaim.isHeld(dir))
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
                .map(\.lastPathComponent) == [dir.lastPathComponent])

            try await coordinator.transcribeNow(dir)

            let transcript = try #require(PostProcessor.readTranscript(dir))
            #expect(transcript.engine == "fishaudio")
            #expect(transcript.model == "transcribe-1-pro")
            #expect(transcript.segments.map(\.speaker) == ["P1A", "P2A", "P3A"])
            #expect(transcript.segments.map(\.text) == ["Piece one.", "Piece two.", "Piece three."])
            #expect(transcript.segments.map(\.start_ms) == [100, 2100, 4100])
            #expect(transcript.segments.map(\.end_ms) == [500, 2500, 4500])
            #expect(stub.requests.count == 4, "piece one was successfully cached before the failure")
            #expect(ProviderCache.files(in: dir).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(
                TranscriptionScratch.fishAudioSliceFolder, isDirectory: true).path))
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).isEmpty)
        }
    }

    private static var fishConfig: [String: Any] {
        [
            "offline_echo_cancellation": false,
            "transcript_echo_filter": false,
            "keep_audio": true,
            "summary": ["enabled": false],
            "speaker_names": ["enabled": false],
            "transcription": ["engine": "fishaudio"],
        ]
    }

    private static func fishSpeech(_ text: String) -> String {
        """
        {"text":"\(text)","duration":1,"speaker_turns":[
          {"speaker":"speaker:0","text":"\(text)","start":0.1,"end":0.5}]}
        """
    }

    @Test("A mixed engine is handed one mix of both tracks")
    func mixedPathThroughTheCoordinator() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a", seconds: 2)
        let engine = FakeEngine("openai", input: .mixed, answer: { _, _ in [
            TranscriptSegment(start: 0, end: 0.9, text: "first voice speaking", speaker: "A"),
            TranscriptSegment(start: 1, end: 1.9, text: "second voice answering", speaker: "B"),
        ] })

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(engine.counts.heard.map(\.lastPathComponent) == ["mixed.m4a"])
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.engine == "openai")
        #expect(transcript.segments.map(\.text) == ["first voice speaking", "second voice answering"])
        #expect(SessionState.value(dir, "transcription_input") as? String == "mixed")
    }
}
