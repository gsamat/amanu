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
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            // First because it is the one line that changes what the reader
            // should do next: everything else describes how the next meeting
            // will go, this one says a meeting is being recorded now.
            checkLiveRecording(recordingsRoot),
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
            checkAutoRecord(),
            checkSummary(),
        ]
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

    static func checkSummary() -> Check {
        let settings = Config.summary()
        guard settings.enabled, settings.backend != "none" else {
            return Check(name: "summary", status: .ok, remediation: nil)
        }
        if hasSummaryBackend(
            anthropicKey: Config.anthropicKey(),
            openAIKey: Config.openAIKey(),
            claudeRuns: Tooling.probe("claude")?.runs == true,
            codexRuns: Tooling.probe("codex")?.runs == true
        ) {
            return Check(name: "summary", status: .ok, remediation: nil)
        }
        return Check(
            name: "summary",
            status: .warn("no key and no claude or codex CLI — will fall back to ollama"),
            remediation: "paste a key in Setup, or run ollama, or set summary.enabled=false"
        )
    }

    static func hasSummaryBackend(
        anthropicKey: String?,
        openAIKey: String?,
        claudeRuns: Bool,
        codexRuns: Bool
    ) -> Bool {
        anthropicKey != nil || openAIKey != nil || claudeRuns || codexRuns
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
                remediation: "System Settings → Privacy & Security → Microphone → enable for amanu (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, and there is no structural precondition left to
    /// check either: an application bundle is its own responsible process,
    /// which `spike/tcc-bundle` measured by playing a tone into its own tap.
    /// What remains unknowable is the grant, and only a recording settles it.
    static func checkSystemAudio() -> Check {
        guard Runtime.isBundled else {
            return Check(
                name: "system audio",
                status: .warn("a bare build records SILENT system audio"),
                remediation: "run Amanu.app — `make app`, then put it in /Applications"
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
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
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
        let provider = TranscriptionCoordinator.cloudProvider(configured: configured)
        if Config.cloudEngines.contains(configured) { return checkCloud(provider) }
        guard Platform.supportsLocalModels else { return checkWithoutLocalModels(provider) }
        return checkParakeet()
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
        provider == "openai" ? Config.openAIKey() : Config.assemblyAIKey()
    }

    private static func cloudKeyPath(_ provider: String) -> URL {
        provider == "openai" ? Config.openAIKeyPath : Config.assemblyAIKeyPath
    }

    private static func cloudName(_ provider: String) -> String {
        provider == "openai" ? "OpenAI" : "AssemblyAI"
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
