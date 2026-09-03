import Foundation

/// Which settings may be reported, derived rather than listed.
///
/// A hand-written list of reportable keys is a list that goes stale the first
/// time somebody adds a setting, and it goes stale in the dangerous
/// direction: nobody notices a key that was let in. So the rule is stated
/// once and applied to `SettingsSchema`, which is already the one place every
/// setting exists.
///
/// The rule: toggles and fixed choices, nothing else. That keeps out paths,
/// key files, names, app lists, model names and language codes — not because
/// somebody reviewed each of them, but because none of them can be a toggle
/// or a choice. A setting added next year is covered before it is written.
enum AnalyticsCatalogue {
    enum SettingKind: Equatable {
        case toggle
        case choice([String])
    }

    /// The analytics switch itself is never reported.
    ///
    /// Sending an event *because* somebody just turned reporting off is
    /// indefensible whatever it would teach us about the opt-out rate, and
    /// the symmetric case — reporting that it was turned on — is only less
    /// obviously so. The number is not worth the sentence it would take to
    /// explain.
    static let neverReported: Set<String> = ["analytics"]

    static var reportableSettings: [String: SettingKind] {
        var reportable: [String: SettingKind] = [:]
        for entry in SettingsSchema.sections.flatMap(\.entries) {
            let key = entry.path.joined(separator: ".")
            guard !neverReported.contains(key) else { continue }
            switch entry.kind {
            case .toggle: reportable[key] = .toggle
            case .choice(let allowed): reportable[key] = .choice(allowed)
            case .number, .text, .list: continue
            }
        }
        return reportable
    }

    /// What is attached to the person rather than to the event: the shape of
    /// the install, resent with every event so that it is never stale.
    ///
    /// This is where "does anybody use the live transcript" and "does
    /// anybody touch diarization" are answered — as a filter over people,
    /// with no event of their own.
    enum PersonProperty: String, CaseIterable, Sendable {
        case analyticsSchemaVersion = "analytics_schema_version"
        case appVersion = "app_version"
        case macosVersion = "macos_version"
        case arch
        case interfaceLanguage = "interface_language"
        case liveTranscription = "live_transcription"
        case speakerNames = "speaker_names"
        case autoRecord = "auto_record"
        case transcriptionEngine = "transcription_engine"
        case transcriptionEnabled = "transcription_enabled"
        case transcriptionCloudProvider = "transcription_cloud_provider"
        case summaryBackend = "summary_backend"
        case summaryEnabled = "summary_enabled"
        case speakerNamesBackend = "speaker_names_backend"
        case keepAudio = "keep_audio"
    }

    static func personProperties() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var values: [PersonProperty: Any] = [
            .analyticsSchemaVersion: 2,
            .macosVersion: "\(os.majorVersion).\(os.minorVersion)",
            .arch: Platform.supportsLocalModels ? "arm64" : "x86_64",
            .interfaceLanguage: InterfaceLanguage.current.rawValue,
            .liveTranscription: Config.liveTranscriptionEnabled(),
            .speakerNames: Config.speakerNames().enabled,
            .autoRecord: autoRecordShape(Config.autoRecord()),
            .transcriptionEngine: Config.transcriptionEngine(),
            .transcriptionEnabled: Config.transcriptionEnabled(),
            .transcriptionCloudProvider: Config.transcriptionCloudProvider(),
            .summaryBackend: Config.summary().backend,
            .summaryEnabled: Config.summary().enabled,
            .speakerNamesBackend: Config.speakerNames().backend,
            .keepAudio: Config.keepAudio(),
        ]
        if let version = appVersion() { values[.appVersion] = version }
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    /// Automatic recording as one word rather than three switches, because
    /// the question anybody asks is which of the four shapes an install is
    /// in, not how it got there.
    static func autoRecordShape(_ settings: Config.AutoRecordSettings) -> String {
        guard settings.enabled else { return "off" }
        switch (settings.micActivity, settings.calendar) {
        case (true, true): return "mic_and_calendar"
        case (true, false): return "mic"
        case (false, true): return "calendar"
        case (false, false): return "off"
        }
    }

    /// Model provenance is deliberately narrowed before it reaches the wire.
    /// Transcript files keep the full local string; analytics gets only a
    /// public model we know or `custom`, never a private fine-tune identifier,
    /// registry namespace, or language hint embedded in provenance.
    static func transcriptionModel(engine: String, provenance: String) -> String {
        switch engine {
        case "parakeet":
            if provenance.contains("0.6b-v3") { return "parakeet-v3" }
            if provenance.contains("0.6b-v2") { return "parakeet-v2" }
            return "custom"
        case "openai":
            return provenance == "gpt-4o-transcribe-diarize"
                ? "gpt-4o-transcribe-diarize" : "custom"
        case "assemblyai":
            let model = provenance.components(separatedBy: " · ").first ?? provenance
            return model == "universal" ? "universal" : "custom"
        default:
            return "unknown"
        }
    }

    /// Same boundary for LLMs. The backend is sent separately; this value says
    /// which public model family was actually asked, without leaking arbitrary
    /// model strings from config or a local Ollama registry.
    static func summaryModel(backend: String, model: String?) -> String {
        switch backend {
        case "claude-cli":
            return "default"
        case "anthropic-api":
            return model == "claude-opus-5" ? "claude-opus-5" : "custom"
        case "codex-cli", "openai-api":
            return model == "gpt-5" ? "gpt-5" : "custom"
        case "ollama":
            return model == "qwen3:8b" ? "qwen3:8b" : "custom-local"
        default:
            return "unknown"
        }
    }

    /// Nil for a bare `swift build`, which has no `Info.plist` for `make app`
    /// to have stamped a version into.
    static func appVersion() -> String? {
        Runtime.appBundle?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
