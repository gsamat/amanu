import Foundation

/// Which engine transcribes a session, and the prepared engines the queue
/// holds on to between sessions.
///
/// Every session is resolved on its own. The queue used to settle on an
/// engine for the first session of a drain and hand that one to every
/// session after it, which ignored two things a session can say about
/// itself: the engine somebody picked for it from the recordings window —
/// "Transcribe again → Whisper" on a meeting that was not to leave the Mac
/// went to AssemblyAI if AssemblyAI was what the queue happened to be
/// holding — and a network failure of its own, after which the local engine
/// the rescue had swapped in went on transcribing every later session too.
///
/// What is held is the preparation, not the choice: prepared engines are kept
/// by name until the queue drains, so a run of sessions that all want
/// parakeet loads it once. Only one local model is held at a time; they are
/// gigabytes each, and a queue that alternates between two would otherwise
/// keep both resident.
actor EngineResolver {
    private struct Key: Hashable {
        let name: String
        let model: String
        let options: String
        let wordTimings: Bool

        init(_ engine: TranscriptionEngine, wordTimings: Bool = false) {
            name = engine.name
            model = engine.model
            options = engine.optionsFingerprint
            self.wordTimings = engine.name == "whisper" && wordTimings
        }
    }

    /// What the resolver asks of the machine. A parameter so that a test can
    /// answer for a Mac with keys, models and a network it does not have.
    struct Environment: Sendable {
        var localModels: @Sendable () -> Bool
        var hasKey: @Sendable (_ provider: String) -> Bool
        var reachable: @Sendable (_ provider: String) async -> Bool
        var cloudEngine: @Sendable (_ provider: String) throws -> TranscriptionEngine
        var localEngine: @Sendable (_ name: String) -> TranscriptionEngine
        var timedLocalEngine: (@Sendable (_ name: String, _ wordTimings: Bool) -> TranscriptionEngine)? = nil

        static let live = Environment(
            localModels: { Platform.supportsLocalModels },
            hasKey: { CloudService(provider: $0).key() != nil },
            reachable: { await CloudService(provider: $0).reachable() },
            cloudEngine: { try EngineResolver.cloudEngine($0) },
            localEngine: { EngineResolver.localEngine(named: $0) },
            timedLocalEngine: { EngineResolver.localEngine(named: $0, wordTimings: $1) })
    }

    /// An engine settled on in advance rather than chosen for the machine at
    /// the moment there is work. Only tests pass one: everything real wants
    /// the configured answer, and wants it decided late.
    private let fixedEngine: TranscriptionEngine?
    let environment: Environment
    private var held: [Key: TranscriptionEngine] = [:]
    private var prepared = Set<Key>()
    /// Engines that could not be prepared during this drain. Asked for again,
    /// they fail at once rather than starting another half-gigabyte download
    /// for every session in the queue; the next drain tries afresh.
    private var unpreparable: [Key: EnginePreparationFailed] = [:]

    init(fixed: TranscriptionEngine? = nil, environment: Environment = .live) {
        fixedEngine = fixed
        self.environment = environment
    }

    /// The engine this session asks for, prepared.
    func engine(for session: URL, wordTimings: Bool = false) async throws -> TranscriptionEngine {
        if let fixedEngine { return try await hold(Key(fixedEngine), fixedEngine) }
        let configured = Self.configuredEngine(for: session)
        if !Self.knownEngines.contains(configured) {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — choosing automatically\n".utf8
            ))
        }
        let provider = Self.cloudProvider(configured: configured)
        let hasKey = environment.hasKey(provider)
        let localModels = environment.localModels()
        if Config.localEngines.contains(configured), !localModels, hasKey {
            FileHandle.standardError.write(Data(
                "warning: \(configured) needs Apple Silicon — transcribing with \(provider)\n".utf8
            ))
        }
        let local = Config.localEngines.contains(configured)
            ? configured : Config.transcriptionLocalEngine()
        switch Self.resolveEngine(configured: configured, hasKey: hasKey, localModels: localModels) {
        case .cloud:
            return try await cloud(provider)
        case .local:
            return try await self.local(named: local, wordTimings: wordTimings)
        case .cloudOrLocal:
            // Cloud when it's actually usable, local otherwise. Asked per
            // session rather than once, because the answer changes: the
            // laptop that recorded a meeting on a train is transcribing it on
            // a train.
            guard await environment.reachable(provider) else {
                FileHandle.standardError.write(Data(
                    "\(provider) unreachable — transcribing locally with \(local)\n".utf8
                ))
                return try await self.local(named: local, wordTimings: wordTimings)
            }
            do {
                return try await cloud(provider)
            } catch {
                return try await self.local(named: local, wordTimings: wordTimings)
            }
        case .unavailable:
            throw EngineUnavailable.noLocalModels
        }
    }

    /// The local engine for one session whose cloud engine failed for want
    /// of a network. The next session is resolved from scratch.
    func localFallback(wordTimings: Bool = false) async throws -> TranscriptionEngine {
        try await local(named: Config.transcriptionLocalEngine(), wordTimings: wordTimings)
    }

    /// Whether the machine can rescue a failed cloud transcription locally.
    nonisolated var canFallBackLocally: Bool { environment.localModels() }

    func release() async {
        let engines = held.values
        held = [:]
        prepared = []
        unpreparable = [:]
        for engine in engines { await engine.release() }
    }

    private func cloud(_ provider: String) async throws -> TranscriptionEngine {
        if let existing = held.first(where: {
            $0.key.name == provider && Self.isCloud($0.value)
        }) {
            return try await hold(existing.key, existing.value)
        }
        let engine = try environment.cloudEngine(provider)
        return try await hold(Key(engine), engine)
    }

    func local(named name: String, wordTimings: Bool = false,
               prepare: Bool = true) async throws -> TranscriptionEngine {
        guard Config.localEngines.contains(name) else {
            throw EngineUnavailable.unknownLocalEngine(name)
        }
        if let fixedEngine {
            guard fixedEngine.name == name else {
                throw EngineUnavailable.unknownLocalEngine(name)
            }
            return try await hold(Key(fixedEngine), fixedEngine, prepare: prepare)
        }
        guard environment.localModels() else { throw EngineUnavailable.noLocalModels }
        let engine = environment.timedLocalEngine?(name, wordTimings)
            ?? environment.localEngine(name)
        let key = Key(engine, wordTimings: wordTimings)
        if let existing = held[key] {
            return try await hold(key, existing, prepare: prepare)
        }
        for (other, engine) in held where other != key && !Self.isCloud(engine) {
            held[other] = nil
            prepared.remove(other)
            await engine.release()
        }
        return try await hold(key, engine, prepare: prepare)
    }

    func prepare(_ engine: TranscriptionEngine) async throws {
        guard let (key, heldEngine) = held.first(where: { $0.value === engine }) else {
            throw EngineUnavailable.unmanagedEngine
        }
        _ = try await hold(key, heldEngine)
    }

    private func hold(_ key: Key, _ engine: TranscriptionEngine,
                      prepare: Bool = true) async throws -> TranscriptionEngine {
        let retained = held[key] ?? engine
        held[key] = retained
        guard prepare, !prepared.contains(key) else { return retained }
        if let failed = unpreparable[key] { throw failed }
        do {
            try await retained.prepare()
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failed = EnginePreparationFailed(engine: key.name, underlying: error)
            unpreparable[key] = failed
            throw failed
        }
        prepared.insert(key)
        return retained
    }

    // MARK: - what the configuration adds up to

    static let knownEngines: Set<String> = Set(["auto"])
        .union(Config.cloudEngines)
        .union(Config.localEngines)

    static func configuredEngine(for session: URL) -> String {
        let requested = SessionState.value(
            session, SessionState.Key.transcriptionEngine) as? String
        return requested.flatMap { knownEngines.contains($0) ? $0 : nil }
            ?? Config.transcriptionEngine()
    }

    /// Which cloud service a configuration means. A configured engine naming
    /// a provider outright is that provider; anything else defers to the
    /// `cloud` setting, which is what the setup window's two cards write.
    static func cloudProvider(configured: String) -> String {
        Config.cloudEngines.contains(configured)
            ? configured
            : Config.transcriptionCloudProvider()
    }

    static func cloudEngine(_ provider: String) throws -> TranscriptionEngine {
        switch CloudService(provider: provider) {
        case .openAI: return try OpenAITranscriptionEngine()
        case .elevenLabs: return try ElevenLabsEngine()
        case .assemblyAI: return try AssemblyAIEngine()
        }
    }

    static func localEngine(named name: String, wordTimings: Bool = false) -> TranscriptionEngine {
        if name == "whisper" { return WhisperEngine(wordTimings: wordTimings) }
        if name == "gigaam" { return GigaAMEngine() }
        return ParakeetEngine()
    }

    static func isCloud(_ engine: TranscriptionEngine) -> Bool {
        switch engine.input {
        case .perTrack: return false
        case .multichannel, .mixed: return true
        }
    }

    /// Which engine the configuration adds up to, before the network is
    /// consulted. Pure so the whole matrix — including the Intel half of the
    /// universal binary, which cannot run a local model at all — is testable
    /// on whichever machine happens to be running the tests.
    enum EngineChoice: Equatable {
        /// Cloud, with no local rescue if it turns out to be unreachable.
        case cloud
        /// Local, no network involved.
        case local
        /// Cloud when it answers, local when it doesn't.
        case cloudOrLocal
        /// Neither: an Intel Mac with no API key. Nothing to run.
        case unavailable
    }

    static func resolveEngine(
        configured: String,
        hasKey: Bool,
        localModels: Bool
    ) -> EngineChoice {
        // An explicit provider keeps failing on a missing key rather than
        // quietly transcribing locally: the person asked for diarization.
        if Config.cloudEngines.contains(configured) { return .cloud }
        // An explicit parakeet on a Mac that cannot run it is the one place
        // we override a stated preference — the alternative is no transcript.
        if Config.localEngines.contains(configured) {
            if localModels { return .local }
            return hasKey ? .cloud : .unavailable
        }
        guard hasKey else { return localModels ? .local : .unavailable }
        return localModels ? .cloudOrLocal : .cloud
    }

    /// No engine this Mac can run. Not permanent — the missing half is an
    /// API key, and adding one is a thing a person does after reading this.
    enum EngineUnavailable: TranscriptionFailure, CustomStringConvertible {
        case noLocalModels
        case unknownLocalEngine(String)
        case unmanagedEngine

        var isPermanent: Bool { false }
        var isEnvironmental: Bool { true }

        var description: String {
            if case .unknownLocalEngine(let name) = self {
                return "unknown local transcription engine \(name)"
            }
            if case .unmanagedEngine = self {
                return "transcription engine is not held by this resolver"
            }
            return "local transcription needs Apple Silicon, and this Mac has no key "
                + "for a cloud engine — put an AssemblyAI one in "
                + "\(Config.assemblyAIKeyPath.path) or an OpenAI one in "
                + "\(Config.openAIKeyPath.path), or an ElevenLabs one in "
                + "\(Config.elevenLabsKeyPath.path) (chmod 600), or set "
                + "ASSEMBLYAI_API_KEY / OPENAI_API_KEY / ELEVENLABS_API_KEY"
        }
    }
}
