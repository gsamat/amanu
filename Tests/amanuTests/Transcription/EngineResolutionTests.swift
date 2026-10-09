import Foundation
import Testing

@testable import amanu

/// Which engine each session in a queue is given.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct EngineResolutionTests {
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
