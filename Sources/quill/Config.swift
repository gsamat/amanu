import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",
///         "language": "ru",
///         "assemblyai": { "api_key_path": "~/.config/assemblyai/token" }
///       },
///       "mic_voice_processing": true,
///       "auto_record": { "enabled": true, "mic_activity": true, "calendar": false },
///       "summary": { "enabled": true, "backend": "auto", "language": "ru" },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name: "parakeet" (local, default) or "assemblyai"
    /// (cloud, diarizing). The coordinator warns and falls back to parakeet
    /// for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// Parakeet model version: "v3" (multilingual, default) or "v2"
    /// (English-only, marginally higher recall on English).
    static func transcriptionModel() -> String {
        transcription()?["model"] as? String ?? "v3"
    }

    /// Two-letter language code for the recording, e.g. "ru". Both engines do
    /// better told than guessing: parakeet uses it as a script hint (so
    /// Russian doesn't come back transliterated), assemblyai as its
    /// language_code (a wrong one there produces confident phonetic garbage).
    /// nil means parakeet runs unhinted and assemblyai auto-detects.
    static func transcriptionLanguage() -> String? {
        guard let code = transcription()?["language"] as? String, !code.isEmpty else { return nil }
        return code
    }

    static let assemblyAIDefaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/assemblyai/token")

    /// AssemblyAI key, in order: ASSEMBLYAI_API_KEY, an inline `api_key` in the
    /// config, then a token file (`api_key_path`, defaulting to
    /// ~/.config/assemblyai/token — the same place the rest of the toolchain
    /// keeps it).
    static func assemblyAIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let inline = assemblyAI()?["api_key"] as? String, !inline.trimmed.isEmpty {
            return inline.trimmed
        }
        let path = (assemblyAI()?["api_key_path"] as? String)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? assemblyAIDefaultKeyPath
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              !contents.trimmed.isEmpty
        else { return nil }
        return contents.trimmed
    }

    /// Override AssemblyAI's default speech model. nil sends nothing and lets
    /// the API pick.
    static func assemblyAISpeechModel() -> String? {
        guard let model = assemblyAI()?["speech_model"] as? String, !model.isEmpty else {
            return nil
        }
        return model
    }

    private static func assemblyAI() -> [String: Any]? {
        transcription()?["assemblyai"] as? [String: Any]
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Whether the transcript merge drops mic segments that duplicate
    /// overlapping system speech — the echo of a meeting played through the
    /// speakers into a raw mic. Costs nothing when there's no echo. Set false
    /// to keep every segment from both tracks. Per-track engines only; a
    /// diarizing engine transcribes one mixed file and can't duplicate.
    static func transcriptEchoFilter() -> Bool {
        load()?["transcript_echo_filter"] as? Bool ?? true
    }

    // MARK: - auto-record

    /// When and how quill starts recording by itself.
    ///
    /// The defaults encode one asymmetry: a missed meeting costs a click, an
    /// unwanted recording costs privacy and disk. So starting takes sustained
    /// evidence (a known call app holding the mic for `startDelay`), stopping
    /// is generous (`stopDelay` of nobody on the mic), short auto-recordings
    /// are thrown away entirely, and two independent backstops — silence and a
    /// hard cap — end a session no matter what the mic says.
    struct AutoRecordSettings {
        var enabled = true
        var micActivity = true
        var calendar = false
        /// How long a call app must hold the mic before this is a meeting.
        var startDelay: TimeInterval = 12
        /// How long nobody may hold the mic before the meeting is over.
        var stopDelay: TimeInterval = 90
        /// Auto-recordings shorter than this are deleted, not transcribed.
        var minDuration: TimeInterval = 45
        /// Hard ceiling on any auto-recording.
        var maxDuration: TimeInterval = 300 * 60
        /// Silence on *both* tracks for this long ends the session regardless
        /// of who holds the mic. The backstop that would have caught
        /// mygranola's overnight 15-hour run.
        var silenceStop: TimeInterval = 10 * 60
        /// Bundle-id prefixes that count as a call. Empty means any process.
        var callApps: [String] = MicActivityMonitor.defaultCallApps
        /// Extra bundle ids / process names to never count.
        var ignoreApps: [String] = []
    }

    static func autoRecord() -> AutoRecordSettings {
        var settings = AutoRecordSettings()
        guard let json = load()?["auto_record"] as? [String: Any] else { return settings }

        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["mic_activity"] as? Bool { settings.micActivity = v }
        if let v = json["calendar"] as? Bool { settings.calendar = v }
        if let v = json["start_delay_seconds"] as? Double { settings.startDelay = v }
        if let v = json["stop_delay_seconds"] as? Double { settings.stopDelay = v }
        if let v = json["min_duration_seconds"] as? Double { settings.minDuration = v }
        if let v = json["max_duration_minutes"] as? Double { settings.maxDuration = v * 60 }
        if let v = json["silence_stop_minutes"] as? Double { settings.silenceStop = v * 60 }
        // An explicit empty list is meaningful here ("count any app"), so this
        // reads presence rather than non-emptiness.
        if let v = json["apps"] as? [String] { settings.callApps = v }
        if let v = json["ignore_apps"] as? [String] { settings.ignoreApps = v }
        return settings
    }

    // MARK: - summary

    /// Post-transcript summarization. `backend: auto` tries, in order: the
    /// Anthropic API if a key is around, then the local `claude` CLI (which
    /// bills to your subscription rather than per token), then ollama.
    struct SummarySettings {
        var enabled = true
        var backend = "auto"
        /// Language for the summary itself; the transcript's own language is
        /// whatever was spoken. nil means "same language as the meeting".
        var language: String?
        var model = "claude-sonnet-5"
        var ollamaModel = "qwen3:8b"
        var apiKeyPath: URL?
    }

    static func summary() -> SummarySettings {
        var settings = SummarySettings()
        guard let json = load()?["summary"] as? [String: Any] else { return settings }

        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["backend"] as? String, !v.isEmpty { settings.backend = v }
        if let v = json["language"] as? String, !v.isEmpty { settings.language = v }
        if let v = json["model"] as? String, !v.isEmpty { settings.model = v }
        if let v = json["ollama_model"] as? String, !v.isEmpty { settings.ollamaModel = v }
        if let v = json["api_key_path"] as? String, !v.isEmpty {
            settings.apiKeyPath = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return settings
    }

    static let anthropicDefaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/anthropic/token")

    /// Anthropic key, in order: ANTHROPIC_API_KEY, then a token file
    /// (`summary.api_key_path`, defaulting to ~/.config/anthropic/token).
    static func anthropicKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        let path = summary().apiKeyPath ?? anthropicDefaultKeyPath
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              !contents.trimmed.isEmpty
        else { return nil }
        return contents.trimmed
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}

private extension String {
    /// Keys read from files and the environment arrive with trailing
    /// newlines more often than not.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
