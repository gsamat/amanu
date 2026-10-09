import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
    /// The failure said to a person, in the language of amanu's windows, for
    /// the alert that stops the app starting. `amanu doctor` stays English,
    /// like every command's output; this is only for the checks that can
    /// refuse a start, which is where somebody meets them in a window.
    var explained: String? = nil
}

enum DoctorReport {
    enum StartupAction: Equatable { case proceed, setup, refuse }

    static func startupAction(checks: [Check], setupPending: Bool) -> StartupAction {
        if !allOK(checks) { return canContinueIntoSetup(checks) ? .setup : .refuse }
        return setupPending ? .setup : .proceed
    }

    static func run(recordingsRoot: URL, includeBackendChecks: Bool = true) -> [Check] {
        let startup = [
            // First because it is the one line that changes what the reader
            // should do next: everything else describes how the next meeting
            // will go, this one says a meeting is being recorded now.
            checkLiveRecording(recordingsRoot),
            checkConfig(),
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
        ]
        guard includeBackendChecks else { return startup }
        return startup + [
            checkTranscription(),
            checkDiarization(),
            checkAutoRecord(),
            checkSummary(),
        ] + [checkSpeakerNames()].compactMap { $0 }
    }

    /// A first-run window can repair a denied microphone grant. It cannot
    /// repair an unwritable recordings root, so that failure must still stop
    /// startup rather than presenting a setup flow that can never succeed.
    static func canContinueIntoSetup(_ checks: [Check]) -> Bool {
        !checks.contains { check in
            if case .fail = check.status { return check.name != "microphone" }
            return false
        }
    }

    /// Whether a recording is underway, which is invisible from everywhere
    /// anyone looks before quitting, replacing or reinstalling amanu
    /// (.issues/005 — a quit during a call cost three minutes of it). The
    /// in-progress manifest is the only honest answer on disk: `meta.json`,
    /// which `amanu sessions` reads, is written when the recording stops.
    ///
    /// Always a warning, never a failure. `allOK` decides whether `amanu
    /// doctor` exits non-zero and whether startup refuses to continue, and a
    /// recording in progress must not stop a second copy from starting — the
    /// person running it is the one who needs to be told.
    static func checkLiveRecording(_ root: URL) -> Check {
        let underway = RecordingSession.inProgress(root: root)
        let now = Date()

        let live = underway.filter(\.ownerIsAlive)
        if !live.isEmpty {
            let listed = live.map { session -> String in
                let name = session.dir.lastPathComponent
                guard let started = session.started else { return "\(name) (started when unknown)" }
                return "\(name) (\(AppController.format(now.timeIntervalSince(started))))"
            }
            return Check(
                name: "recording",
                status: .warn("in progress — " + listed.joined(separator: ", ")),
                remediation: "stop it in amanu before quitting or replacing the app: the session "
                    + "is saved either way, but nothing is recorded until amanu runs again"
            )
        }

        // A manifest whose owner is gone is a crashed session, not a live one.
        // Saying so is worth a line: the audio is intact and the next launch
        // adopts it, which is not obvious from a folder with no transcript.
        guard underway.isEmpty else {
            let names = underway.map(\.dir.lastPathComponent).joined(separator: ", ")
            return Check(
                name: "recording",
                status: .warn("interrupted and not yet recovered — " + names),
                remediation: "start amanu: the next launch writes the meta.json that crash left "
                    + "unwritten and transcribes the audio"
            )
        }

        return Check(name: "recording", status: .ok, remediation: nil)
    }

    /// The config file, when amanu is not doing what it says.
    ///
    /// A warning and not a failure even when the file cannot be read at all:
    /// a failure stops startup, and recording is the one thing a broken config
    /// must not be allowed to stop.
    static func checkConfig() -> Check {
        let problems = Config.problems()
        guard !problems.isEmpty else { return Check(name: "config", status: .ok, remediation: nil) }
        let path = Config.path.path
        let unreadable = problems.contains {
            if case .unreadable = $0 { return true }
            return false
        }
        return Check(
            name: "config",
            status: .warn(problems.map(\.explanation).joined(separator: " ")),
            remediation: unreadable
                ? "fix \(path) by hand, or move it aside to start again from the defaults: "
                    + "mv \(path) \(path).broken"
                : "correct the values in \(path), or clear them in Settings"
        )
    }

    /// Says out loud what amanu will do on its own, because the surprising
    /// failure mode of an automatic recorder is not that it fails — it's that
    /// it records something you didn't expect it to.
    static func checkAutoRecord() -> Check {
        let settings = Config.autoRecord()
        guard settings.enabled else {
            return Check(
                name: "auto-record",
                status: .ok,
                remediation: nil
            )
        }
        guard #available(macOS 14.4, *) else {
            return Check(
                name: "auto-record",
                status: .warn("needs macOS 14.4 for per-process mic detection — start recordings by hand"),
                remediation: nil
            )
        }
        var triggers: [String] = []
        if settings.micActivity {
            triggers.append(settings.callApps.isEmpty
                ? "any app opening the mic"
                : "\(settings.callApps.count) known call apps")
        }
        if settings.calendar { triggers.append("calendar events") }
        guard !triggers.isEmpty else {
            return Check(
                name: "auto-record",
                status: .warn("on, but every trigger is disabled"),
                remediation: "set auto_record.mic_activity or auto_record.calendar"
            )
        }
        return Check(
            name: "auto-record",
            status: .warn("on — will record automatically from " + triggers.joined(separator: " and ")),
            remediation: "turn it off in the menu, or set auto_record.enabled=false"
        )
    }

    // MARK: - summaries and names

    /// What this machine has for each backend, gathered once so the same
    /// facts decide both checks and so the decision can be tested without
    /// any of them being real.
    struct ModelFacts {
        var claudeRuns = false
        var codexRuns = false
        var anthropicKey = false
        var openAIKey = false
        /// Why the OpenAI Base URL will not be used, when it won't.
        var openAIEndpointProblem: String?
        var ollama: OllamaStatus = .unreachable
    }

    enum OllamaStatus: Equatable {
        /// Not asked, because nothing configured would use it.
        case notAsked
        /// Nothing answered at the Base URL.
        case unreachable
        /// The Base URL itself is refused — see `OpenAICompatible.EndpointError`.
        case refused(String)
        case running([OllamaClient.Model])
    }

    /// The summary's check: the backend it is configured for, walked the way
    /// `LLMBackend` will walk it, including whether Ollama is answering and
    /// has the model — rather than whether any key or CLI exists anywhere,
    /// which is what it used to ask regardless of `summary.backend`.
    static func checkSummary() -> Check {
        let route = MeetingEgress.route(for: .summary)
        return evaluate(
            "summary", route: route, facts: gatherFacts(for: [route]),
            settings: Config.summary())
    }

    /// Naming's own check, shown only when naming has a backend of its own;
    /// otherwise it goes wherever the summary goes, and the summary's line
    /// already says where that is.
    static func checkSpeakerNames() -> Check? {
        guard Config.speakerNames().ownBackend != nil else { return nil }
        let route = MeetingEgress.route(for: .speakerNames)
        guard route != nil else {
            return Check(name: "speaker names", status: .ok, remediation: nil)
        }
        return evaluate(
            "speaker names", route: route, facts: gatherFacts(for: [route]),
            settings: Config.summary())
    }

    static func evaluate(
        _ name: String,
        route: MeetingEgress.Route?,
        facts: ModelFacts,
        settings: Config.SummarySettings
    ) -> Check {
        guard let route else { return Check(name: name, status: .ok, remediation: nil) }
        let wanted = route.preference == "auto" ? LLMBackend.names : [route.preference]
        guard route.preference == "auto" || LLMBackend.names.contains(route.preference) else {
            return Check(
                name: name,
                status: .warn("backend \"\(route.preference)\" is not one amanu knows — "
                    + "no model will be asked"),
                remediation: "set it to auto or one of " + LLMBackend.names.joined(separator: ", "))
        }

        var ready: [String] = []
        var problems: [(String, String)] = []
        for backend in wanted {
            if let problem = problem(backend, facts: facts, settings: settings) {
                problems.append(problem)
            } else {
                ready.append(backend)
            }
        }

        if let first = ready.first {
            var said = "via \(first)"
            if ready.count > 1 { said += " (then \(ready.dropFirst().joined(separator: ", ")))" }
            // Where the meeting goes is what this line is for, so a route
            // that sends it off the Mac is a warning, as a cloud
            // transcription engine is — informative, never blocking.
            if first == "ollama" {
                if case .running(let models) = facts.ollama,
                   SetupSelection.ollamaModel(named: settings.ollamaModel, in: models)?
                       .isRemote == true {
                    return Check(name: name, status: .warn(
                        said + " · \(settings.ollamaModel) is an Ollama cloud model, so the "
                            + "transcript leaves this machine"), remediation: nil)
                }
                guard OllamaClient.isLocal(baseURL: settings.ollamaBaseURL) else {
                    return Check(name: name, status: .warn(
                        said + " · the transcript goes to \(settings.ollamaBaseURL)"),
                        remediation: nil)
                }
                return Check(name: name, status: .ok, remediation: nil)
            }
            return Check(
                name: name, status: .warn(said + " · the transcript leaves this machine"),
                remediation: nil)
        }
        guard route.preference != "auto", let (what, fix) = problems.first else {
            return Check(
                name: name,
                status: .warn("no backend is ready — " + problems.map(\.0).joined(separator: "; ")),
                remediation: "paste a key in Setup, install the claude or codex CLI, or start "
                    + "Ollama — or set summary.enabled=false")
        }
        return Check(name: name, status: .warn(what), remediation: fix)
    }

    /// Why one backend cannot answer, with what to do about it; nil when it
    /// can.
    private static func problem(
        _ backend: String, facts: ModelFacts, settings: Config.SummarySettings
    ) -> (String, String)? {
        switch backend {
        case "claude-cli":
            return facts.claudeRuns ? nil
                : ("the claude CLI is not installed or does not run",
                   "install Claude Code and sign in, or choose another backend")
        case "codex-cli":
            return facts.codexRuns ? nil
                : ("the codex CLI is not installed or does not run",
                   "install Codex and sign in, or choose another backend")
        case "anthropic-api":
            return facts.anthropicKey ? nil
                : ("no Anthropic key", "paste an Anthropic key in Setup")
        case "openai-api":
            if let why = facts.openAIEndpointProblem {
                return ("the OpenAI Base URL is refused: \(why)", "fix summary.openai_base_url")
            }
            return facts.openAIKey ? nil : ("no OpenAI key", "paste an OpenAI key in Setup")
        case "ollama":
            switch facts.ollama {
            case .notAsked:
                return ("Ollama was not asked", "run amanu doctor")
            case .refused(let why):
                return ("the Ollama Base URL is refused: \(why)", "fix summary.ollama_base_url")
            case .unreachable:
                return ("nothing answers at \(settings.ollamaBaseURL)",
                        "start Ollama, or fix summary.ollama_base_url")
            case .running(let models):
                guard SetupSelection.ollamaModel(named: settings.ollamaModel, in: models) != nil
                else {
                    return ("Ollama is running but \(settings.ollamaModel) is not pulled",
                            "ollama pull \(settings.ollamaModel)")
                }
                return nil
            }
        default:
            return ("\(backend) is not a backend amanu knows", "choose another backend")
        }
    }

    /// Ask the machine only what the routes would use: `--version` of a CLI
    /// that is never going to be run proves nothing, and neither does a
    /// request to an Ollama nobody configured.
    static func gatherFacts(for routes: [MeetingEgress.Route?]) -> ModelFacts {
        let wanted = Set(routes.compactMap { $0 }.flatMap { route in
            route.preference == "auto" ? LLMBackend.names : [route.preference]
        })
        let settings = Config.summary()
        var facts = ModelFacts()
        if wanted.contains("claude-cli") { facts.claudeRuns = Tooling.probe("claude")?.runs == true }
        if wanted.contains("codex-cli") { facts.codexRuns = Tooling.probe("codex")?.runs == true }
        facts.anthropicKey = Config.anthropicKey() != nil
        facts.openAIKey = Credentials.summaryOpenAIKey() != nil
        do {
            _ = try OpenAICompatible.url(baseURL: settings.openAIBaseURL, path: "models")
        } catch {
            facts.openAIEndpointProblem = "\(error)"
        }
        facts.ollama = wanted.contains("ollama")
            ? ollamaStatus(baseURL: settings.ollamaBaseURL) : .notAsked
        return facts
    }

    /// Ollama's answer, waited for: the doctor is synchronous and prints in
    /// order, and `listModels` gives up after two seconds of its own.
    static func ollamaStatus(baseURL: String) -> OllamaStatus {
        do {
            _ = try OpenAICompatible.url(baseURL: baseURL, path: "api/tags")
        } catch {
            return .refused("\(error)")
        }
        guard Home.current.discoversTools else { return .unreachable }
        final class Answer: @unchecked Sendable { var models: [OllamaClient.Model]? }
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            answer.models = try? await OllamaClient.listModels(baseURL: baseURL)
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success, let models = answer.models else {
            return .unreachable
        }
        return .running(models)
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested"),
                remediation: "open Setup before a meeting; recording can also raise the prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for amanu (or your terminal)",
                explained: localised(
                    "Microphone access is denied. Allow amanu in System Settings → Privacy & "
                        + "Security → Microphone.",
                    "Доступ к микрофону запрещён. Разрешите его amanu в Системных настройках → "
                        + "Конфиденциальность и безопасность → Микрофон.")
            )
        @unknown default:
            return Check(
                name: "microphone", status: .fail("unknown state"), remediation: nil,
                explained: localised(
                    "macOS gave an answer amanu does not know about microphone access.",
                    "macOS ответила про доступ к микрофону то, чего amanu не знает."))
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, and there is no structural precondition left to
    /// check either: an application bundle is its own responsible process,
    /// which `spike/tcc-bundle` measured by playing a tone into its own tap.
    /// What remains unknowable is the grant, and only a recording settles it.
    static func checkSystemAudio() -> Check {
        checkSystemAudio(
            isBundled: Runtime.isBundled,
            heardAt: SetupState.systemAudioHeardAt(),
            now: Date()
        )
    }

    static func checkSystemAudio(isBundled: Bool, heardAt: Date?, now: Date) -> Check {
        guard isBundled else {
            return Check(
                name: "system audio",
                status: .warn("a bare build records SILENT system audio"),
                remediation: "run Amanu.app — `make app`, then put it in /Applications"
            )
        }
        if let heardAt, heardAt <= now {
            let days = max(0, Int(now.timeIntervalSince(heardAt) / (24 * 60 * 60)))
            let age = days == 1 ? "1 day ago" : "\(days) days ago"
            let recent = SetupPermissions.rememberedSystemAudio(
                heardAt: heardAt, now: now) == .heard
            return Check(
                name: "system audio",
                status: recent ? .ok : .warn("last successful tone test is stale"),
                remediation: "last successful tone test: \(age); run `amanu setup` to test again"
            )
        }
        return Check(
            name: "system audio",
            status: .warn("grant state unknowable until first use"),
            remediation: "if system.caf is silent: System Settings → Privacy & Security → System Audio Recording Only"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory",
                explained: localised(
                    "The recordings folder \(root.path) can't be created. Check the permissions "
                        + "on the folder it is in, or choose another in the config file.",
                    "Не удаётся создать папку записей \(root.path). Проверьте права на папку, "
                        + "в которой она лежит, или укажите другую в файле настроек.")
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory",
                explained: localised(
                    "amanu can't write into the recordings folder \(root.path). Check its "
                        + "permissions, or choose another in the config file.",
                    "amanu не может писать в папку записей \(root.path). Проверьте права на неё "
                        + "или укажите другую в файле настроек.")
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model or a missing API key after an important
    /// meeting: check whatever the configured engine needs, up front.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let configured = Config.transcriptionEngine()
        let provider = EngineResolver.cloudProvider(configured: configured)
        if Config.cloudEngines.contains(configured) { return checkCloud(provider) }
        guard Platform.supportsLocalModels else { return checkWithoutLocalModels(provider) }
        return checkParakeet()
    }

    static func checkDiarization() -> Check {
        let configured = Config.value(.localDiarization, in: Config.raw()) as? NSNumber
        let requested = configured.map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } == true
        let directory = DiarizationModelStore.shared.directory
        let ready = DiarizationModelStore.isReady(at: directory)
        let bytes = ModelStorage.bytes(of: directory)
        if requested && !Platform.supportsLocalModels {
            return Check(name: "local diarization", status: .warn("needs Apple Silicon"),
                         remediation: "turn off transcription.local_diarization on this Mac")
        }
        if requested && !ready {
            return Check(name: "local diarization",
                         status: .warn(bytes > 0 ? "model set incomplete or corrupt" : "model not downloaded"),
                         remediation: "download the pinned Community-1 model in Settings; "
                            + "every segmentation, embedding, FBank and PLDA asset must verify")
        }
        if ready {
            return Check(name: "local diarization",
                         status: .warn("\(requested ? "on" : "off") · model ready · "
                            + "\(ModelStorage.describe(bytes: bytes)) · Community-1 scoped CC-BY-4.0 · "
                            + "revision \(DiarizationModelStore.revision.prefix(12))"),
                         remediation: nil)
        }
        return Check(name: "local diarization", status: .ok, remediation: nil)
    }

    /// An Intel Mac, where anything but an explicit cloud engine would like to
    /// run a local model and none of them can. Report what will actually
    /// happen — the cloud engine, or nothing at all — because the time to
    /// learn there is no engine is before the meeting.
    private static func checkWithoutLocalModels(_ provider: String) -> Check {
        guard cloudKey(provider) != nil else {
            return Check(
                name: "transcription",
                status: .warn("local transcription needs Apple Silicon and there is no "
                    + "\(cloudName(provider)) key"),
                remediation: "printf '%s' YOUR_KEY > \(cloudKeyPath(provider).path)"
                    + " && chmod 600 \(cloudKeyPath(provider).path)"
            )
        }
        return checkCloud(provider)
    }

    private static func checkParakeet() -> Check {
        // Resolved through the engine so the cache we check can't drift from
        // the model we'd actually download.
        let version = ParakeetEngine.configuredVersion()

        // v2 doesn't fail on other languages, it returns English-looking
        // nonsense — the failure you only notice by reading the transcript.
        // Catch the mismatched config here rather than after the meeting.
        if version == .v2,
           let language = Config.transcriptionLanguage(),
           language != "en" {
            return Check(
                name: "transcription",
                status: .warn("parakeet v2 is English-only but language is \"\(language)\""),
                remediation: "set transcription.model to \"v3\" — v2 won't fail on "
                    + "\(language), it'll return phonetic nonsense"
            )
        }

        let cache = AsrModels.defaultCacheDirectory(for: version)
        if AsrModels.modelsExist(at: cache, version: version) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        let label = version == .v2 ? "v2" : "v3"
        return Check(
            name: "transcription",
            status: .warn("parakeet \(label) models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    /// The cloud engine has no models to cache; what it can be missing is a
    /// key. Language is worth reporting either way: the engine detects it, and
    /// what a configured one narrows is the shortlist it detects within.
    private static func checkCloud(_ provider: String) -> Check {
        // A warning, not a failure: a missing key costs you the transcript,
        // and refusing to launch over it would cost you the recording too.
        guard cloudKey(provider) != nil else {
            return Check(
                name: "transcription",
                status: .warn("\(provider) engine selected but no API key — transcripts will fail"),
                remediation: "printf '%s' YOUR_KEY > \(cloudKeyPath(provider).path)"
                    + " && chmod 600 \(cloudKeyPath(provider).path)"
            )
        }
        let expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        guard !expected.isEmpty else {
            return Check(
                name: "transcription",
                status: .warn("\(provider) · key ok · no language set (detects from any)"),
                remediation: "set transcription.language (e.g. \"ru\") — detection over every "
                    + "language it knows can pick wrong on a short or noisy meeting"
            )
        }
        return Check(
            name: "transcription",
            status: .warn(
                "\(provider) · key ok · expecting \(expected.joined(separator: "+")) "
                    + "· audio leaves this machine"),
            remediation: nil
        )
    }

    private static func cloudKey(_ provider: String) -> String? {
        switch provider {
        case "openai": return Config.openAIKey()
        case "elevenlabs": return Config.elevenLabsKey()
        default: return Config.assemblyAIKey()
        }
    }

    private static func cloudKeyPath(_ provider: String) -> URL {
        switch provider {
        case "openai": return Config.openAIKeyPath
        case "elevenlabs": return Config.elevenLabsKeyPath
        default: return Config.assemblyAIKeyPath
        }
    }

    private static func cloudName(_ provider: String) -> String {
        TranscriptionChoice.displayName(provider)
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
