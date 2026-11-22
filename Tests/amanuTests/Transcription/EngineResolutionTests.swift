import Foundation
import Testing

@testable import amanu

/// Which engine each session in a queue is given.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct EngineResolutionTests {
    private final class TimingEngine: TranscriptionEngine {
        let wrapped: FakeEngine
        let optionsFingerprint: String

        init(_ wrapped: FakeEngine, wordTimings: Bool) {
            self.wrapped = wrapped
            optionsFingerprint = "word_timestamps=\(wordTimings)"
        }

        var name: String { wrapped.name }
        var model: String { wrapped.model }
        var input: TranscriptionInput { wrapped.input }
        func prepare() async throws { try await wrapped.prepare() }
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            try await wrapped.transcribe(audio)
        }
        func release() async { await wrapped.release() }
    }

    private actor OneTurnRuntime: LocalDiarizationRuntime {
        private var calls = 0
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            calls += 1
            return [SpeakerTurn(speakerID: "remote", start: 0, end: 1)]
        }
        func release() async {}
        func count() -> Int { calls }
    }

    private static func engine(of session: URL) -> String? {
        PostProcessor.readTranscript(session)?.engine
    }

    @Test("Whisper timing mode gets a separately prepared cached engine")
    func timingModeChangesCacheKey() async throws {
        let plain = FakeEngine("whisper")
        let timed = FakeEngine("whisper")
        var environment = EngineResolver.Environment.fake(local: { _ in plain })
        environment.timedLocalEngine = { _, words in words ? timed : plain }
        let resolver = EngineResolver(environment: environment)

        _ = try await resolver.local(named: "whisper")
        _ = try await resolver.local(named: "whisper", wordTimings: true)
        _ = try await resolver.local(named: "whisper", wordTimings: true)

        #expect(plain.counts.prepared == 1)
        #expect(plain.counts.released == 1)
        #expect(timed.counts.prepared == 1)
        await resolver.release()
        #expect(timed.counts.released == 1)
    }

    @Test("Explicit local retry keeps the injected fixed engine")
    func localRetryUsesFixedEngine() async throws {
        let fixed = FakeEngine("parakeet")
        let resolver = EngineResolver(fixed: fixed,
            environment: .fake(localModels: false))
        _ = try await resolver.local(named: "parakeet", wordTimings: true)
        _ = try await resolver.local(named: "parakeet", wordTimings: true)
        #expect(fixed.counts.prepared == 1)
    }

    @Test("Cached-word retry holds a model without preparing it until ASR is needed")
    func unpreparedLocalIsManaged() async throws {
        let fake = FakeEngine("whisper")
        let resolver = EngineResolver(environment: .fake(local: { _ in fake }))
        let held = try await resolver.local(named: "whisper", wordTimings: true,
            prepare: false)
        #expect(fake.counts.prepared == 0)

        try await resolver.prepare(held)
        try await resolver.prepare(held)
        #expect(fake.counts.prepared == 1)
        await resolver.release()
        #expect(fake.counts.released == 1)
    }

    /// "Transcribe again → Whisper" on a meeting that was never to leave the
    /// Mac, queued behind a session that had already loaded the cloud engine,
    /// used to be uploaded to that cloud engine.
    @Test("A session's own engine choice is honoured while the queue holds another")
    func perSessionChoiceWins() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false,
            "transcription": ["engine": "assemblyai"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let first = try recordings.session("2026-09-28-a")
        let private_ = try recordings.session(
            "2026-09-28-b", state: [SessionState.Key.transcriptionEngine: "whisper"])

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake()), onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(Self.engine(of: first) == "assemblyai")
        #expect(Self.engine(of: private_) == "whisper")
    }

    @Test("A network failure moves that session to the local engine, and only that one")
    func fallbackIsPerSession() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let offline = try recordings.session("2026-09-28-a")
        let online = try recordings.session("2026-09-28-b")
        let cloud = FakeEngine("assemblyai", input: .multichannel, answer: { audio, call in
            if call == 1 { throw URLError(.notConnectedToInternet) }
            return try FakeEngine.bothSides(audio, call)
        })

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(cloud: { _ in cloud })),
            onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(Self.engine(of: offline) == "parakeet")
        #expect(Self.engine(of: online) == "assemblyai")
    }

    @Test("A mid-upload cloud fallback keeps Whisper word timings for requested speakers")
    func cloudFallbackKeepsDiarizationTimings() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["engine": "auto", "local_engine": "whisper",
                              "local_diarization": true, "diarization_model": "community-1"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("cloud-fallback")
        let cloud = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw URLError(.networkConnectionLost)
        })
        let answer: FakeEngine.Answer = { audio, _ in
            let text = audio.lastPathComponent.contains("them") ? "remote" : "local"
            return [TranscriptSegment(start: 0, end: 1, text: text,
                                       words: [TranscriptWord(start: 0, end: 1, text: text)])]
        }
        let plain = FakeEngine("whisper", answer: answer)
        let timed = FakeEngine("whisper", answer: answer)
        let plainEngine = TimingEngine(plain, wordTimings: false)
        let timedEngine = TimingEngine(timed, wordTimings: true)
        var environment = EngineResolver.Environment.fake(
            cloud: { _ in cloud }, local: { _ in plainEngine })
        environment.timedLocalEngine = { _, words in words ? timedEngine : plainEngine }
        let runtime = OneTurnRuntime()
        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: environment), onStop: { nil },
            diarizerFactory: { _ in runtime }, modelFingerprint: { _ in "test-model" })

        try await coordinator.transcribeNow(dir)

        let asr = try #require(DiarizationArtifacts.readASR(dir))
        #expect(asr.optionsFingerprint == DiarizationArtifacts.hash(
            "whisper", "fake", "word_timestamps=true"))
        #expect(plain.counts.heard.isEmpty)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(PostProcessor.readTranscript(dir)?.segments.contains {
            $0.speaker.hasPrefix("them")
        } == true)
        let heard = timed.counts.heard.count
        #expect(heard > 0)
        #expect(await runtime.count() == 1)

        try await coordinator.diarizeNow(dir)
        #expect(timed.counts.heard.count == heard)
        #expect(await runtime.count() == 1)
    }

    @Test("A refused key is not network trouble, and is not rescued locally")
    func unauthorizedIsNotRescued() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let session = try recordings.session("2026-09-28-a")
        let local = FakeEngine("parakeet")
        let cloud = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw CloudHTTP.Failure.unauthorized(
                service: "assemblyai", what: "upload", status: 401, body: "")
        })

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(cloud: { _ in cloud }, local: { _ in local })),
            onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(Self.engine(of: session) == nil)
        #expect(local.counts.heard.isEmpty)
    }

    @Test("An engine is prepared once for every session that wants it")
    func preparedEnginesAreReused() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "parakeet"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        for name in ["2026-09-28-a", "2026-09-28-b", "2026-09-28-c"] {
            try recordings.session(name)
        }
        let parakeet = FakeEngine("parakeet")

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { _ in parakeet })),
            onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(parakeet.counts.prepared == 1)
        #expect(parakeet.counts.heard.count == 6)
        #expect(parakeet.counts.released == 1)
    }

    /// Local models are gigabytes each; a queue that alternates between two
    /// must not keep both loaded.
    @Test("Only one local model is held at a time")
    func oneLocalModelAtATime() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "parakeet"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        try recordings.session("2026-09-28-a")
        try recordings.session(
            "2026-09-28-b", state: [SessionState.Key.transcriptionEngine: "whisper"])
        let parakeet = FakeEngine("parakeet"), whisper = FakeEngine("whisper")

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { $0 == "whisper" ? whisper : parakeet })),
            onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(parakeet.counts.released == 1)
        #expect(whisper.counts.prepared == 1)
    }
}
