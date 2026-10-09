import Foundation

extension Config {
    /// Every key amanu reads from the config file, and the only way to read
    /// one.
    ///
    /// The settings used to be described twice: `Config` read them with a
    /// default written inline, and `SettingsSchema` listed them again with a
    /// path, a default and a kind for the window. Nothing tied the two
    /// together except a test holding a third, hand-written list of "every key
    /// Config reads", which could not notice a key it had not been told about.
    ///
    /// Now the readers below take a `Key` and nothing else, so a new setting
    /// cannot be read without a case here; `SettingsSchemaTests` holds this
    /// list and the schema's to be the same set; and the defaults of switches,
    /// numbers, choices and plain values come from the schema rather than
    /// being written a second time — so the placeholder the window shows is
    /// the value amanu uses, by construction.
    enum Key: String, CaseIterable, Sendable {
        case recordingsDir = "recordings_dir"
        case onStop = "on_stop"
        case transcriptionEnabled = "transcription.enabled"
        case transcriptionEngine = "transcription.engine"
        case transcriptionLocalEngine = "transcription.local_engine"
        case transcriptionCloud = "transcription.cloud"
        case transcriptionOpenAIModel = "transcription.openai.model"
        case transcriptionOpenAIKeyPath = "transcription.openai.api_key_path"
        case transcriptionModel = "transcription.model"
        case transcriptionLanguage = "transcription.language"
        case localDiarization = "transcription.local_diarization"
        case diarizationThreshold = "transcription.diarization_threshold"
        case assemblyAIKey = "transcription.assemblyai.api_key"
        case assemblyAIKeyPath = "transcription.assemblyai.api_key_path"
        case assemblyAISpeechModel = "transcription.assemblyai.speech_model"
        case elevenLabsKey = "transcription.elevenlabs.api_key"
        case elevenLabsKeyPath = "transcription.elevenlabs.api_key_path"
        case liveTranscription = "live_transcription.enabled"
        case micVoiceProcessing = "mic_voice_processing"
        case transcriptEchoFilter = "transcript_echo_filter"
        case offlineEchoCancellation = "offline_echo_cancellation"
        case userName = "user_name"
        case speakerNamesEnabled = "speaker_names.enabled"
        case speakerNamesBackend = "speaker_names.backend"
        case speakerNamesModel = "speaker_names.model"
        case autoRecordEnabled = "auto_record.enabled"
        case autoRecordMicActivity = "auto_record.mic_activity"
        case autoRecordCalendar = "auto_record.calendar"
        case autoRecordStartDelay = "auto_record.start_delay_seconds"
        case autoRecordStopDelay = "auto_record.stop_delay_seconds"
        case autoRecordMinDuration = "auto_record.min_duration_seconds"
        case autoRecordMaxDuration = "auto_record.max_duration_minutes"
        case autoRecordSilenceStop = "auto_record.silence_stop_minutes"
        case autoRecordApps = "auto_record.apps"
        case autoRecordAnyApp = "auto_record.any_app"
        case autoRecordIgnoreApps = "auto_record.ignore_apps"
        case systemAudio = "system_audio"
        case calendar
        case dockIcon = "dock_icon"
        case menuBarIcon = "menu_bar_icon"
        case window
        case interfaceLanguage = "interface_language"
        case keepAudio = "keep_audio"
        case summaryEnabled = "summary.enabled"
        case summaryBackend = "summary.backend"
        case summaryLanguage = "summary.language"
        case summaryModel = "summary.model"
        case summaryOllamaModel = "summary.ollama_model"
        case summaryOpenAIModel = "summary.openai_model"
        case summaryOpenAIBaseURL = "summary.openai_base_url"
        case summaryOpenAICompatible = "summary.openai_compatible"
        case summaryOllamaBaseURL = "summary.ollama_base_url"
        case summaryTemplate = "summary.template"
        case summaryKeyPath = "summary.api_key_path"
        case summaryOpenAIKeyPath = "summary.openai_api_key_path"
        case summaryOpenAICompatibleKeyPath = "summary.openai_compatible_api_key_path"
        case analytics

        /// The key as a path into the JSON: `["auto_record", "enabled"]`.
        var path: [String] { rawValue.split(separator: ".").map(String.init) }
    }

    // MARK: - reading one setting

    /// Whatever the file holds for `key`, of any type, or nil.
    static func value(_ key: Key, in json: [String: Any]?) -> Any? {
        var node: Any? = json
        for part in key.path {
            guard let object = node as? [String: Any] else { return nil }
            node = object[part]
        }
        return node
    }

    /// An on/off setting: the file's answer if it is one, the schema's default
    /// otherwise.
    static func flag(_ key: Key, in json: [String: Any]?) -> Bool {
        value(key, in: json) as? Bool ?? defaultFlag(key)
    }

    /// A number: the file's, or the schema's default.
    static func number(_ key: Key, in json: [String: Any]?) -> Double {
        value(key, in: json) as? Double ?? defaultNumber(key)
    }

    /// A string setting whose default is a value — a choice, a model name, a
    /// URL: the file's if it says something, the schema's default if not.
    static func string(_ key: Key, in json: [String: Any]?) -> String {
        text(key, in: json) ?? defaultString(key)
    }

    /// A string setting with no default value, only a description of what
    /// happens without one: the file's, or nil.
    static func text(_ key: Key, in json: [String: Any]?) -> String? {
        guard let string = value(key, in: json) as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }

    /// A list of strings, or nil when the file has none — which is not the
    /// same as an empty list, for the settings where empty means something.
    static func list(_ key: Key, in json: [String: Any]?) -> [String]? {
        value(key, in: json) as? [String]
    }

    // MARK: - defaults, from the schema

    /// A reader asking for a default the schema does not give is a programming
    /// error: the setting was added here and its entry was not, or the entry
    /// describes its default in words. Caught where it is written in any
    /// build with assertions — every test run — and harmless in a release.
    static func defaultFlag(_ key: Key) -> Bool {
        if case .flag(let value)? = SettingsSchema.valueDefault(for: key) { return value }
        assertionFailure("SettingsSchema has no on/off default for \(key.rawValue)")
        return false
    }

    static func defaultNumber(_ key: Key) -> Double {
        if case .number(let value)? = SettingsSchema.valueDefault(for: key) { return value }
        assertionFailure("SettingsSchema has no numeric default for \(key.rawValue)")
        return 0
    }

    static func defaultString(_ key: Key) -> String {
        if case .string(let value)? = SettingsSchema.valueDefault(for: key) { return value }
        assertionFailure("SettingsSchema has no default value for \(key.rawValue)")
        return ""
    }
}
