import Foundation

/// Optional user config at ~/.config/amanu/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "auto",
///         "language": "ru",
///         "assemblyai": { "api_key_path": "~/.config/amanu/keys/assemblyai" }
///       },
///       "mic_voice_processing": true,
///       "keep_audio": false,
///       "calendar": true,
///       "auto_record": { "enabled": true, "mic_activity": true, "calendar": false },
///       "summary": { "enabled": true, "backend": "auto", "language": "ru" },
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript, the names and the
/// summary are written, or right after recording when transcription is
/// disabled.
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

    /// Shell command to spawn once a session is finished — transcript, names
    /// and summary — or right after recording, if transcription is disabled.
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

    /// Two-letter code for the language meetings are *mostly* in, e.g. "ru".
    ///
    /// Not a pin. Both engines identify the language themselves; what this
    /// narrows is the shortlist they choose from, and English is on that
    /// shortlist whatever this says — see `MeetingLanguages`. nil means no
    /// expectation at all.
    static func transcriptionLanguage() -> String? {
        guard let code = transcription()?["language"] as? String, !code.isEmpty else { return nil }
        return code
    }

    /// Whether a meeting should feed the optional local streaming model while
    /// it is being recorded. This is deliberately opt-in: recording and the
    /// canonical post-meeting transcript do not depend on the extra model.
    ///
    /// The streaming model is local-only, so on a Mac without local models the
    /// answer is no whatever the config says — read here rather than at every
    /// call site, because a stored `true` from a migrated config is otherwise
    /// indistinguishable from a switch the person just flipped.
    static func liveTranscriptionEnabled() -> Bool {
        liveTranscriptionEnabled(in: load())
    }

    static func liveTranscriptionEnabled(in json: [String: Any]?) -> Bool {
        guard Platform.supportsLocalModels else { return false }
        let settings = json?["live_transcription"] as? [String: Any]
        return settings?["enabled"] as? Bool ?? false
    }

    /// amanu's own key drawer: one directory, mode 0700, one file per
    /// service, mode 0600.
    ///
    /// Keys used to be written to the shared locations — ~/.config/assemblyai,
    /// ~/.config/anthropic, ~/.config/openai — which several unrelated tools
    /// read and write. That is how a working AssemblyAI key became two bytes
    /// one evening and every meeting after it failed with HTTP 401. What amanu
    /// writes now belongs to amanu; what other tools keep is still *read*, so
    /// nobody has to paste a key twice.
    static let keysDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/amanu/keys", isDirectory: true)

    static let assemblyAIKeyPath = keysDir.appendingPathComponent("assemblyai")
    static let openAIKeyPath = keysDir.appendingPathComponent("openai")
    static let anthropicKeyPath = keysDir.appendingPathComponent("anthropic")

    /// Where the rest of a machine's toolchain tends to keep the same secret.
    /// Read-only as far as amanu is concerned.
    static let assemblyAISharedKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/assemblyai/token")
    static let openAISharedKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/openai/token")
    static let anthropicSharedKeyPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/anthropic/token")

    static func secret(at path: URL) -> String? {
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              !contents.trimmed.isEmpty
        else { return nil }
        return contents.trimmed
    }

    /// AssemblyAI key, in order: ASSEMBLYAI_API_KEY, an inline `api_key` in the
    /// config, a token file named by `api_key_path`, amanu's own key file, and
    /// finally the shared one this machine may already have.
    static func assemblyAIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let inline = assemblyAI()?["api_key"] as? String, !inline.trimmed.isEmpty {
            return inline.trimmed
        }
        if let configured = (assemblyAI()?["api_key_path"] as? String)
            .map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) {
            return secret(at: configured)
        }
        return secret(at: assemblyAIKeyPath) ?? secret(at: assemblyAISharedKeyPath)
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
    /// as "me".
    ///
    /// Default on. A meeting held through the speakers puts the far end on the
    /// mic track too, and every consumer of that track then has to work around
    /// it — the per-track engine transcribes them twice and needs `EchoFilter`
    /// to undo it, and speaker attribution has to tell a loud echo from the
    /// person actually in the room. Cancelling at capture is the only place
    /// that fixes it for all of them at once.
    ///
    /// The costs are real but small: the live voice unit ducks other playback,
    /// so music during a recording gets quieter, and on headphones it works
    /// for nothing because there is no echo to cancel. Set false to record raw.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? true
    }

    /// Whether the transcript merge drops mic segments that duplicate
    /// overlapping system speech — the echo of a meeting played through the
    /// speakers into a raw mic. Costs nothing when there's no echo. Set false
    /// to keep every segment from both tracks. Per-track engines only; a
    /// diarizing engine transcribes one mixed file and can't duplicate.
    static func transcriptEchoFilter() -> Bool {
        load()?["transcript_echo_filter"] as? Bool ?? true
    }

    // MARK: - speaker names

    /// What to call the person doing the recording, instead of "me".
    ///
    /// Unset falls back to the machine's account name, but only when that
    /// reads as a person's name — see `SpeakerNamer.personName`.
    static func userName() -> String? {
        guard let name = load()?["user_name"] as? String, !name.trimmed.isEmpty else {
            return nil
        }
        return name.trimmed
    }

    /// Putting real names to the transcript's mechanical speaker labels.
    struct SpeakerNamesSettings {
        var enabled = true
        /// Which model to ask, in `LLMBackend`'s vocabulary.
        var backend = "auto"
        /// Anthropic model for this pass specifically. nil uses the summary's,
        /// which is the strong one — fine, but naming is an easier job than
        /// summarizing and doesn't need to cost the same.
        var model: String?
    }

    static func speakerNames() -> SpeakerNamesSettings {
        var settings = SpeakerNamesSettings()
        guard let json = load()?["speaker_names"] as? [String: Any] else { return settings }
        if let v = json["enabled"] as? Bool { settings.enabled = v }
        if let v = json["backend"] as? String, !v.isEmpty { settings.backend = v }
        if let v = json["model"] as? String, !v.isEmpty { settings.model = v }
        return settings
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

    /// Whether the audio outlives the transcript it was recorded for.
    ///
    /// Off by default, and that is a real trade rather than a tidy-up: a
    /// meeting is about a gigabyte an hour, and once it has been written down
    /// almost nobody plays it back. What it costs is the only cure for a bad
    /// transcript — a wrong language, a worse engine, a name the model got
    /// backwards — because re-transcribing needs the audio and nothing else
    /// can reconstruct it. Turn it on and the two temporary PCM tracks become
    /// one compact stereo M4A: mic on the left, system audio on the right.
    ///
    /// Only ever applies to a session that got its transcript. A session that
    /// failed keeps its audio whatever this says — that recording is the only
    /// copy of the meeting, and the next attempt is all it has.
    static func keepAudio() -> Bool {
        load()?["keep_audio"] as? Bool ?? false
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

    /// OpenAI key, in order: OPENAI_API_KEY, a token file named by
    /// `summary.openai_api_key_path`, amanu's own key file, then the shared one.
    static func openAIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = (summaryJSON()?["openai_api_key_path"] as? String)
            .map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) {
            return secret(at: configured)
        }
        return secret(at: openAIKeyPath) ?? secret(at: openAISharedKeyPath)
    }

    private static func summaryJSON() -> [String: Any]? {
        load()?["summary"] as? [String: Any]
    }

    /// Anthropic key, in order: ANTHROPIC_API_KEY, a token file named by
    /// `summary.api_key_path`, amanu's own key file, then the shared one.
    static func anthropicKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = summary().apiKeyPath { return secret(at: configured) }
        return secret(at: anthropicKeyPath) ?? secret(at: anthropicSharedKeyPath)
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
