import Foundation

/// Optional user config at ~/.config/amanu/config.json:
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
///       "calendar": true,
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
        .appendingPathComponent(".config/amanu/config.json")

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

    /// Configured engine: `auto` (default), `parakeet` (local) or
    /// `assemblyai` (cloud, diarizing).
    ///
    /// `auto` means "the best one available right now": assemblyai when there
    /// is a key and the API answers, parakeet otherwise. That ordering is
    /// deliberate — assemblyai is better on Russian and tells apart several
    /// people sharing one channel, and parakeet needs neither network nor
    /// account, so it is what should catch a session recorded on a train.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "auto"
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

    /// When and how amanu starts recording by itself.
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

    /// Whose audio lands on the far-end track: `app` (default) records only
    /// the call app's output, `all` records everything the Mac plays.
    ///
    /// `app` is better on both counts that matter. The transcript stops
    /// collecting music and notification dings, and — the reason this exists —
    /// "the far end has gone quiet" starts meaning the call ended rather than
    /// "nothing at all is playing on this machine". With `all`, a video opened
    /// after a meeting kept a recording alive for ten extra minutes
    /// (2026.08.18). Falls back to everything when the call app can't be
    /// identified: recording too much is a small wrong, recording nothing is
    /// the wrong that loses the meeting.
    static func systemAudioScope() -> String {
        load()?["system_audio"] as? String ?? "app"
    }

    /// Read the calendar to name sessions after the meeting they belong to.
    ///
    /// Separate from `auto_record.calendar`, which is about *starting* a
    /// recording from a calendar event. Naming is the cheaper, more broadly
    /// useful half: it costs the same one-time permission prompt but doesn't
    /// depend on your calendar being an accurate description of what you're
    /// actually doing.
    static func useCalendar() -> Bool {
        load()?["calendar"] as? Bool ?? true
    }

    /// Show amanu in the Dock (and in ⌘-Tab) rather than running as a
    /// menu-bar-only accessory. On by default: the menu bar hides its status
    /// item when it runs out of room, and a recorder whose only indicator can
    /// silently disappear is a recorder you can't trust.
    static func dockIcon() -> Bool {
        load()?["dock_icon"] as? Bool ?? true
    }

    /// Open the status window at launch. Off for anyone who'd rather start
    /// from the Dock icon each time.
    static func showWindowAtLaunch() -> Bool {
        load()?["window"] as? Bool ?? true
    }

    /// Whether finished sessions have their PCM tracks re-encoded as AAC once
    /// the transcript exists. Recording uncompressed is what makes a session
    /// survive a crash; keeping it uncompressed afterwards just fills the disk.
    static func compressTracks() -> Bool {
        load()?["compress_tracks"] as? Bool ?? true
    }

    /// Keep the PCM next to the compressed tracks instead of deleting it. For
    /// anyone who wants the original audio — it costs about a gigabyte an hour.
    static func keepUncompressed() -> Bool {
        load()?["keep_uncompressed"] as? Bool ?? false
    }

    // MARK: - summary

    /// Post-transcript summarization. `backend: auto` walks the chain in
    /// LLMBackend: the local `claude` CLI, the Anthropic API, the `codex` CLI,
    /// the OpenAI API, then ollama — subscriptions before metered keys.
    struct SummarySettings {
        var enabled = true
        var backend = "auto"
        /// Summarizing is where a cheap model quietly costs you something:
        /// a missed decision in a meeting you'll never listen to again. The
        /// difference between tiers is a few cents per meeting, so the default
        /// is the strong one.
        var openAIModel = "gpt-5"
        /// Language for the summary itself; the transcript's own language is
        /// whatever was spoken. nil means "same language as the meeting".
        var language: String?
        var model = "claude-opus-5"
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
        if let v = json["openai_model"] as? String, !v.isEmpty { settings.openAIModel = v }
        if let v = json["api_key_path"] as? String, !v.isEmpty {
            settings.apiKeyPath = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
        }
        return settings
    }

    static let openAIDefaultKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/openai/token")

    /// OpenAI key, in order: OPENAI_API_KEY, then a token file
    /// (`summary.openai_api_key_path`, defaulting to ~/.config/openai/token).
    static func openAIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        let path = (summaryJSON()?["openai_api_key_path"] as? String)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? openAIDefaultKeyPath
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              !contents.trimmed.isEmpty
        else { return nil }
        return contents.trimmed
    }

    private static func summaryJSON() -> [String: Any]? {
        load()?["summary"] as? [String: Any]
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

    // MARK: - writing

    /// The config file as it is on disk, or an empty object when there isn't
    /// one yet. The settings window reads this to show what has been set,
    /// as distinct from what merely defaults.
    static func raw() -> [String: Any] { load() ?? [:] }

    /// Set (or, with a nil value, clear) one setting, addressed by its path
    /// into the JSON — `["auto_record", "start_delay_seconds"]`.
    ///
    /// Clearing rather than writing the default is deliberate: a config that
    /// only contains what you changed keeps reading as a list of your
    /// decisions, and a default that improves later reaches you instead of
    /// being frozen into your file the first time you opened a window.
    @discardableResult
    static func update(path: [String], value: Any?) -> Bool {
        guard let first = path.first else { return false }
        var json = raw()

        if path.count == 1 {
            if let value { json[first] = value } else { json.removeValue(forKey: first) }
        } else {
            var nested = json[first] as? [String: Any] ?? [:]
            nested = updated(nested, path: Array(path.dropFirst()), value: value)
            if nested.isEmpty { json.removeValue(forKey: first) } else { json[first] = nested }
        }
        return write(json)
    }

    private static func updated(
        _ object: [String: Any], path: [String], value: Any?
    ) -> [String: Any] {
        var object = object
        guard let first = path.first else { return object }
        if path.count == 1 {
            if let value { object[first] = value } else { object.removeValue(forKey: first) }
            return object
        }
        var nested = object[first] as? [String: Any] ?? [:]
        nested = updated(nested, path: Array(path.dropFirst()), value: value)
        if nested.isEmpty { object.removeValue(forKey: first) } else { object[first] = nested }
        return object
    }

    private static func write(_ json: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't write \(path.path): \(error)\n".utf8
            ))
            return false
        }
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
