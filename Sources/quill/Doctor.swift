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
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects. But the *structural* precondition is checkable,
    /// and it's the one that actually bites: TCC attributes the tap request to
    /// the responsible process, so a terminal-launched quill has no identity
    /// to grant, raises no prompt, and records a full-length silent file
    /// (rca-002). Under launchd quill is its own responsible process.
    static func checkSystemAudio() -> Check {
        // Reparented to launchd — either we were started by it, or our parent
        // already exited. For the daemon this is the case that matters.
        if getppid() == 1 {
            return Check(
                name: "system audio",
                status: .warn("running under launchd — grant state unknowable until first use"),
                remediation: "if system.caf is silent: System Settings → Privacy & Security → System Audio Recording Only"
            )
        }
        guard FileManager.default.fileExists(atPath: Install.agentPlistURL.path) else {
            return Check(
                name: "system audio",
                status: .warn("no LaunchAgent — a terminal-launched quill records SILENT system audio"),
                remediation: "quill install --launch-at-login, then record via the agent (see .issues/rca-002)"
            )
        }
        return Check(
            name: "system audio",
            status: .warn("LaunchAgent installed; this process isn't under it"),
            remediation: "record via the agent — system audio captured from a terminal-launched quill is silent"
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
        switch Config.transcriptionEngine() {
        case "assemblyai": return checkAssemblyAI()
        default: return checkParakeet()
        }
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
    /// key. Language matters more here than for parakeet — a wrong
    /// language_code returns fluent-looking phonetic nonsense — so an unset
    /// one is worth saying out loud.
    private static func checkAssemblyAI() -> Check {
        // A warning, not a failure: a missing key costs you the transcript,
        // and refusing to launch over it would cost you the recording too.
        guard Config.assemblyAIKey() != nil else {
            return Check(
                name: "transcription",
                status: .warn("assemblyai engine selected but no API key — transcripts will fail"),
                remediation: "printf '%s' YOUR_KEY > \(Config.assemblyAIDefaultKeyPath.path)"
                    + " && chmod 600 \(Config.assemblyAIDefaultKeyPath.path)"
            )
        }
        guard let language = Config.transcriptionLanguage() else {
            return Check(
                name: "transcription",
                status: .warn("assemblyai · key ok · no language set (auto-detect)"),
                remediation: "set transcription.language (e.g. \"ru\") — auto-detect on a "
                    + "short or noisy meeting can pick wrong"
            )
        }
        return Check(
            name: "transcription",
            status: .warn("assemblyai · key ok · language \(language) · audio leaves this machine"),
            remediation: nil
        )
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
