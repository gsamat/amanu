import Foundation

/// Optional user config at ~/.config/amanu/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "auto",
///         "cloud": "assemblyai",
///         "language": "ru",
///         "assemblyai": { "api_key_path": "~/.config/amanu/keys/assemblyai" }
///       },
///       "mic_voice_processing": false,
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
    /// Where the file is. Asked of `Home` every time rather than fixed at
    /// startup, so that a test runs against a file of its own — see `Home`.
    static var path: URL { Home.current.configFile }

    static var defaultRoot: URL { Home.current.defaultRecordings }

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = text(.recordingsDir, in: load()) else { return nil }
        return Home.current.expanding(dir, isDirectory: true)
    }

    /// Shell command to spawn once a session is finished — transcript, names
    /// and summary — or right after recording, if transcription is disabled.
    static func onStop() -> String? {
        text(.onStop, in: load())
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        flag(.transcriptionEnabled, in: load())
    }

    /// Configured engine: `auto` (default), a local engine, or a cloud
    /// provider by name — `assemblyai`, `openai`, or `elevenlabs`.
    ///
    /// `auto` means "the best one available right now": the cloud provider
    /// when there is a key and the API answers, parakeet otherwise. That
    /// ordering is deliberate — a cloud engine is better on Russian and tells
    /// apart several people sharing one channel, and parakeet needs neither
    /// network nor account, so it is what should catch a session recorded on
    /// a train.
    static func transcriptionEngine() -> String {
        string(.transcriptionEngine, in: load())
    }

    /// Which local engine `auto` falls back to. Kept separately for the same
    /// reason as the cloud provider: both cloud and local may be enabled, so
    /// the single `engine` value cannot remember both choices.
    static func transcriptionLocalEngine() -> String {
        let configured = string(.transcriptionLocalEngine, in: load())
        guard localEngines.contains(configured) else {
            let fallback = defaultString(.transcriptionLocalEngine)
            FileHandle.standardError.write(Data(
                "warning: unknown local engine \"\(configured)\" — using \(fallback)\n".utf8
            ))
            return fallback
        }
        return configured
    }

    /// Which cloud engine `auto` reaches for. It only decides the provider —
    /// whether the cloud is used at all is `engine`. A provider named in
    /// `engine` wins over this setting.
    ///
    /// The two are separate settings because they answer separate questions,
    /// and the setup window asks them separately: a switch for "may audio
    /// leave this Mac", provider cards for "to whom". Turning the switch off
    /// and on again should not lose the answer to the second one.
    static func transcriptionCloudProvider() -> String {
        let configured = string(.transcriptionCloud, in: load())
        guard cloudEngines.contains(configured) else {
            let fallback = defaultString(.transcriptionCloud)
            FileHandle.standardError.write(Data(
                "warning: unknown cloud engine \"\(configured)\" — using \(fallback)\n".utf8
            ))
            return fallback
        }
        return configured
    }

    /// The cloud engines, by the name they carry in the config and in
    /// transcript.json's provenance.
    static let cloudEngines: Set<String> = ["assemblyai", "openai", "elevenlabs"]
    static let localEngines: Set<String> = ["parakeet", "whisper", "gigaam"]

    /// OpenAI's transcription model. The default is the only one of theirs
    /// that returns timings and speakers; the setting exists for the day they
    /// ship a better one, not as a menu to browse.
    static func openAITranscriptionModel() -> String {
        string(.transcriptionOpenAIModel, in: load())
    }

    /// Parakeet model version: "v3" (multilingual, default) or "v2"
    /// (English-only, marginally higher recall on English).
    static func transcriptionModel() -> String {
        string(.transcriptionModel, in: load())
    }

    /// Whether the far side of a per-track transcript should be diarized
    /// locally: "them A" and "them B" instead of one flat "them".
    ///
    /// Off by default. It is a second local model to download and a second
    /// pass over the system track, and one person on the other end — the
    /// ordinary two-party call — is exactly what the flat label is right for.
    /// It matters when several people share the far end's room mic.
    ///
    /// Read as written and gated where it is used, the way
    /// `transcriptionModel` is: the answer only means anything on a Mac that
    /// can run the model, and saying so here would hide a stored `true` from
    /// the doctor.
    static func transcriptionLocalDiarization() -> Bool {
        flag(.transcriptionLocalDiarization, in: load())
    }

    /// Two-letter code for the language meetings are *mostly* in, e.g. "ru".
    ///
    /// Not a pin. Both engines identify the language themselves; what this
    /// narrows is the shortlist they choose from, and English is on that
    /// shortlist whatever this says — see `MeetingLanguages`. nil means no
    /// expectation at all.
    static func transcriptionLanguage() -> String? {
        text(.transcriptionLanguage, in: load())
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
        return flag(.liveTranscription, in: json)
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
    static var keysDir: URL { Home.current.keysDirectory }

    static var assemblyAIKeyPath: URL { keysDir.appendingPathComponent("assemblyai") }
    static var openAIKeyPath: URL { keysDir.appendingPathComponent("openai") }
    static var elevenLabsKeyPath: URL { keysDir.appendingPathComponent("elevenlabs") }
    static var anthropicKeyPath: URL { keysDir.appendingPathComponent("anthropic") }

    /// Where the rest of a machine's toolchain tends to keep the same secret.
    /// Read-only as far as amanu is concerned.
    ///
    /// Two filenames each, because both are in the wild: `token` is what the
    /// CLIs write, `api_key` is what people write by hand — and a key sitting
    /// in the second one while the window says "no key yet" is a person being
    /// asked to paste something they already have.
    static var assemblyAISharedKeyPaths: [URL] { sharedKeyPaths("assemblyai") }
    static var openAISharedKeyPaths: [URL] { sharedKeyPaths("openai") }
    static var elevenLabsSharedKeyPaths: [URL] { sharedKeyPaths("elevenlabs") }
    static var anthropicSharedKeyPaths: [URL] { sharedKeyPaths("anthropic") }

    private static func sharedKeyPaths(_ service: String) -> [URL] {
        Home.current.sharedKeyFiles(for: service)
    }

    /// The first of `paths` that holds something.
    private static func secret(atAnyOf paths: [URL]) -> String? {
        for path in paths {
            if let found = secret(at: path) { return found }
        }
        return nil
    }

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
        if let env = Home.current.variable("ASSEMBLYAI_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        let json = load()
        if let inline = text(.assemblyAIKey, in: json) { return inline.trimmed }
        if let configured = (value(.assemblyAIKeyPath, in: json) as? String)
            .map({ Home.current.expanding($0) }) {
            return secret(at: configured)
        }
        return secret(at: assemblyAIKeyPath) ?? secret(atAnyOf: assemblyAISharedKeyPaths)
    }

    /// Override AssemblyAI's default speech model. nil sends nothing and lets
    /// the API pick.
    static func assemblyAISpeechModel() -> String? {
        text(.assemblyAISpeechModel, in: load())
    }

    static func elevenLabsKey() -> String? {
        if let env = Home.current.variable("ELEVENLABS_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        let json = load()
        if let inline = text(.elevenLabsKey, in: json) { return inline.trimmed }
        if let configured = (value(.elevenLabsKeyPath, in: json) as? String)
            .map({ Home.current.expanding($0) }) {
            return secret(at: configured)
        }
        return secret(at: elevenLabsKeyPath) ?? secret(atAnyOf: elevenLabsSharedKeyPaths)
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me".
    ///
    /// Off by default. VoiceProcessingIO is a duplex call route rather than an
    /// input-only effect: enabling it interrupts and attenuates what the person
    /// hears for the whole recording. Raw capture leaves playback untouched;
    /// per-track and multichannel transcription remove speaker echo later.
    /// Set true only when capture-time cancellation matters more than playback.
    static func micVoiceProcessing() -> Bool {
        micVoiceProcessing(in: load())
    }

    /// The same decision against supplied JSON, so an absent key's behavior is
    /// testable without reading or rewriting the person's real config file.
    static func micVoiceProcessing(in config: [String: Any]?) -> Bool {
        flag(.micVoiceProcessing, in: config)
    }

    /// Whether the transcript merge drops mic segments that duplicate
    /// overlapping system speech — the echo of a meeting played through the
    /// speakers into a raw mic. Costs nothing when there's no echo. Set false
    /// to keep every segment from both tracks. Runs on per-track and
    /// multichannel transcripts; a mixed transcript has no duplicate segment.
    static func transcriptEchoFilter() -> Bool {
        flag(.transcriptEchoFilter, in: load())
    }

    /// Clean a derived microphone file before ASR without opening a playback
    /// device. Originals and the user's live call audio are never processed.
    static func offlineEchoCancellation() -> Bool {
        flag(.offlineEchoCancellation, in: load())
    }

    // MARK: - speaker names

    /// What to call the person doing the recording, instead of "me".
    ///
    /// Unset falls back to the machine's account name, but only when that
    /// reads as a person's name — see `SpeakerNamer.personName`.
    static func userName() -> String? {
        text(.userName, in: load())?.trimmed
    }

    /// Putting real names to the transcript's mechanical speaker labels.
    struct SpeakerNamesSettings {
        var enabled = Config.defaultFlag(.speakerNamesEnabled)
        /// Which model to ask, in `LLMBackend`'s vocabulary, or `summary` to
        /// go wherever the summary goes. Read it through `ownBackend`, and act
        /// on it only through `MeetingEgress`.
        var backend = Config.defaultString(.speakerNamesBackend)
        /// Anthropic model for this pass specifically. nil uses the summary's,
        /// which is the strong one — fine, but naming is an easier job than
        /// summarizing and doesn't need to cost the same.
        var model: String?

        /// The backend naming was given of its own, or nil when it follows
        /// the summary.
        var ownBackend: String? { backend == Config.followsSummary ? nil : backend }
    }

    /// The word for "whatever the summary does", and the default.
    static let followsSummary = "summary"

    static func speakerNames() -> SpeakerNamesSettings {
        let json = load()
        var settings = SpeakerNamesSettings()
        settings.enabled = flag(.speakerNamesEnabled, in: json)
        settings.backend = string(.speakerNamesBackend, in: json)
        settings.model = text(.speakerNamesModel, in: json)
        return settings
    }

    // MARK: - auto-record

    /// When and how amanu starts recording by itself.
    ///
    /// The defaults encode one asymmetry: a missed meeting costs a click, an
    /// unwanted recording costs privacy and disk. So starting takes sustained
    /// evidence (a known call app holding the mic for `startDelay`), stopping
    /// takes only `stopDelay`, short auto-recordings are thrown away entirely,
    /// and two independent backstops — silence and a hard cap — end a session
    /// no matter what the mic says.
    struct AutoRecordSettings {
        var enabled = Config.defaultFlag(.autoRecordEnabled)
        var micActivity = Config.defaultFlag(.autoRecordMicActivity)
        var calendar = Config.defaultFlag(.autoRecordCalendar)
        /// How long a call app must hold the mic before this is a meeting.
        var startDelay: TimeInterval = Config.defaultNumber(.autoRecordStartDelay)
        /// How long nobody may hold the mic before the meeting is over.
        ///
        /// Short, because the condition is already strong: the call app has
        /// let go of the microphone *and* the far end has made no sound. A
        /// minute and a half of that used to be tacked onto the end of every
        /// recording for nothing.
        ///
        /// Not shorter than this, though. The mic is sampled once per
        /// `AutoRecordController.tick` and any held sample clears the idle
        /// clock, so 15 means four clean samples in a row — a whole tick of
        /// margin over the two that anything below 10 would come down to.
        /// The gap when a call app rebuilds its input unit (a device change
        /// mid-call) is a second or two, nowhere near that; an app that closes
        /// the input for longer would still fool this, and nobody has measured
        /// one.
        var stopDelay: TimeInterval = Config.defaultNumber(.autoRecordStopDelay)
        /// Auto-recordings shorter than this are deleted, not transcribed.
        var minDuration: TimeInterval = Config.defaultNumber(.autoRecordMinDuration)
        /// Hard ceiling on any auto-recording.
        var maxDuration: TimeInterval = Config.defaultNumber(.autoRecordMaxDuration) * 60
        /// Silence on *both* tracks for this long ends the session regardless
        /// of who holds the mic. The backstop that would have caught
        /// mygranola's overnight 15-hour run.
        var silenceStop: TimeInterval = Config.defaultNumber(.autoRecordSilenceStop) * 60
        /// Bundle-id prefixes or app names that count as a call. Empty means any process.
        var callApps: [String] = MicActivityMonitor.defaultCallApps
        /// Extra bundle ids / process names to never count.
        var ignoreApps: [String] = []
    }

    static func autoRecord() -> AutoRecordSettings {
        let json = load()
        var settings = AutoRecordSettings()
        // On by default, and a recording nobody asked for is the one wrong
        // that cannot be taken back: while the file has never been readable,
        // the switch is taken to be off. The backstops still apply to a
        // recording started by hand.
        settings.enabled = flag(.autoRecordEnabled, in: json) && !settingsUnknown
        settings.micActivity = flag(.autoRecordMicActivity, in: json)
        settings.calendar = flag(.autoRecordCalendar, in: json)
        settings.startDelay = number(.autoRecordStartDelay, in: json)
        settings.stopDelay = number(.autoRecordStopDelay, in: json)
        settings.minDuration = number(.autoRecordMinDuration, in: json)
        settings.maxDuration = number(.autoRecordMaxDuration, in: json) * 60
        settings.silenceStop = number(.autoRecordSilenceStop, in: json) * 60
        // An explicit empty list is meaningful here ("count any app"), so this
        // reads presence rather than non-emptiness.
        if let v = list(.autoRecordApps, in: json) { settings.callApps = v }
        if flag(.autoRecordAnyApp, in: json) { settings.callApps = [] }
        if let v = list(.autoRecordIgnoreApps, in: json) { settings.ignoreApps = v }
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
        string(.systemAudio, in: load())
    }

    /// Read the calendar to name sessions after the meeting they belong to.
    ///
    /// Separate from `auto_record.calendar`, which is about *starting* a
    /// recording from a calendar event. Naming is the cheaper, more broadly
    /// useful half: it costs the same one-time permission prompt but doesn't
    /// depend on your calendar being an accurate description of what you're
    /// actually doing.
    static func useCalendar() -> Bool {
        flag(.calendar, in: load())
    }

    /// Show amanu in the Dock (and in ⌘-Tab) rather than running as a
    /// menu-bar-only accessory. On by default: the menu bar hides its status
    /// item when it runs out of room, and a recorder whose only indicator can
    /// silently disappear is a recorder you can't trust.
    static func dockIcon() -> Bool {
        flag(.dockIcon, in: load())
    }

    /// Show amanu's feather in the menu bar, with the clock beside it while a
    /// meeting is being recorded. On by default, and it may be turned off
    /// together with the Dock icon: with neither, amanu is a program with no
    /// icon anywhere, and the way back to its window is to open Amanu again —
    /// from Spotlight or from Applications, which reaches the copy already
    /// running rather than starting a second one.
    static func menuBarIcon() -> Bool {
        flag(.menuBarIcon, in: load())
    }

    /// Open the status window at launch. Off for anyone who'd rather start
    /// from the Dock icon each time.
    static func showWindowAtLaunch() -> Bool {
        flag(.window, in: load())
    }

    /// What language amanu's own windows are written in: `auto` (default,
    /// meaning the Mac's own languages decide), `en` or `ru`.
    ///
    /// Named at length rather than as `language`, because two settings called
    /// language already exist and answer different questions —
    /// `transcription.language` is what meetings are held in and
    /// `summary.language` is what summaries are written in. A bare `language`
    /// in this file would read as a third member of that family instead of as
    /// the one setting here that is about amanu's own words. See
    /// `InterfaceLanguage`.
    static func interfaceLanguage() -> String? {
        text(.interfaceLanguage, in: load())
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
        flag(.keepAudio, in: load())
    }

    // MARK: - summary

    /// Post-transcript summarization. `backend: auto` walks the chain in
    /// LLMBackend: the local `claude` CLI, the Anthropic API, the `codex` CLI,
    /// the OpenAI API, then ollama — subscriptions before metered keys.
    struct SummarySettings {
        var enabled = Config.defaultFlag(.summaryEnabled)
        var backend = Config.defaultString(.summaryBackend)
        /// Summarizing is where a cheap model quietly costs you something:
        /// a missed decision in a meeting you'll never listen to again. The
        /// difference between tiers is a few cents per meeting, so the default
        /// is the strong one.
        var openAIModel = Config.defaultString(.summaryOpenAIModel)
        var openAIBaseURL = Config.defaultString(.summaryOpenAIBaseURL)
        var openAICompatible = false
        /// Language for the summary itself; the transcript's own language is
        /// whatever was spoken. nil means "same language as the meeting".
        var language: String?
        var model = Config.defaultString(.summaryModel)
        /// `model` when the config file names one, nil when it is the
        /// default. The API always needs a model; the `claude` CLI is only
        /// told one when somebody chose it, and otherwise keeps whatever
        /// Claude Code is set to — which a subscription may be limited to.
        var configuredModel: String?
        var ollamaModel = Config.defaultString(.summaryOllamaModel)
        var ollamaBaseURL = Config.defaultString(.summaryOllamaBaseURL)
        var template = Config.defaultString(.summaryTemplate)
        var apiKeyPath: URL?
        /// Whether the file says anything about Ollama — a model or a server
        /// of its own. Without either, the Ollama at the end of `auto` is a
        /// guess nobody made; see `LLMBackend.isUnchosenFallback`.
        var ollamaConfigured = false
    }

    static func summary() -> SummarySettings {
        summary(in: load())
    }

    /// The summary settings against supplied JSON, so defaults and custom
    /// templates are testable without reading or rewriting the person's real
    /// config file.
    static func summary(in root: [String: Any]?) -> SummarySettings {
        var settings = SummarySettings()
        settings.enabled = flag(.summaryEnabled, in: root)
        settings.backend = string(.summaryBackend, in: root)
        settings.language = text(.summaryLanguage, in: root)
        settings.model = string(.summaryModel, in: root)
        settings.configuredModel = text(.summaryModel, in: root)
        settings.ollamaModel = string(.summaryOllamaModel, in: root)
        settings.openAIModel = string(.summaryOpenAIModel, in: root)
        settings.openAIBaseURL = string(.summaryOpenAIBaseURL, in: root).trimmed
        // Older configs chose compatible services through the URL alone.
        let compatible = (root?["summary"] as? [String: Any])?["openai_compatible"] as? Bool
        settings.openAICompatible = compatible ?? !Credentials.isOpenAIItself(settings.openAIBaseURL)
        if let compatible {
            settings.openAIBaseURL = compatible
                ? (text(.summaryOpenAIBaseURL, in: root)?.trimmed ?? "")
                : defaultString(.summaryOpenAIBaseURL)
        }
        settings.ollamaBaseURL = string(.summaryOllamaBaseURL, in: root).trimmed
        settings.template = string(.summaryTemplate, in: root)
        settings.apiKeyPath = text(.summaryKeyPath, in: root).map { Home.current.expanding($0) }
        settings.ollamaConfigured = text(.summaryOllamaModel, in: root) != nil
            || text(.summaryOllamaBaseURL, in: root) != nil
        return settings
    }

    /// The OpenAI key — for OpenAI's own API, which is where the
    /// transcription engine sends it. In order: OPENAI_API_KEY, a token file
    /// named by `transcription.openai.api_key_path` (or, in a config written
    /// before that setting, `summary.openai_api_key_path` — see
    /// `openAIKeyFile`), amanu's own key file, then the shared one.
    static func openAIKey() -> String? {
        if let env = Home.current.variable("OPENAI_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = openAIKeyFile(in: load()) { return secret(at: configured) }
        return secret(at: openAIKeyPath) ?? secret(atAnyOf: openAISharedKeyPaths)
    }

    /// The file the config names for the OpenAI key, if it names one.
    ///
    /// `summary.openai_api_key_path` used to answer this for transcription
    /// too, and the summary sent the same file's key to whatever server its
    /// Base URL named — so an OpenAI key went to OpenRouter the moment the
    /// URL changed, and an OpenRouter key named there went to OpenAI with
    /// every transcription. Now transcription has a setting of its own, and
    /// the summary's is borrowed only while the summary itself talks to
    /// OpenAI, when the file it names is an OpenAI key by the summary's own
    /// account. A compatible server's key is a third setting,
    /// `summary.openai_compatible_api_key_path`.
    static func openAIKeyFile(in json: [String: Any]?) -> URL? {
        if let own = text(.transcriptionOpenAIKeyPath, in: json) {
            return Home.current.expanding(own)
        }
        guard Credentials.isOpenAIItself(summary(in: json).openAIBaseURL),
              let summarys = text(.summaryOpenAIKeyPath, in: json)
        else { return nil }
        return Home.current.expanding(summarys)
    }

    /// Anthropic key, in order: ANTHROPIC_API_KEY, a token file named by
    /// `summary.api_key_path`, amanu's own key file, then the shared one.
    static func anthropicKey() -> String? {
        if let env = Home.current.variable("ANTHROPIC_API_KEY"),
           !env.trimmed.isEmpty {
            return env.trimmed
        }
        if let configured = summary().apiKeyPath { return secret(at: configured) }
        return secret(at: anthropicKeyPath) ?? secret(atAnyOf: anthropicSharedKeyPaths)
    }

    // MARK: - the file itself

    /// What is at `path`, told apart the three ways that matter.
    ///
    /// "No file" and "a file nobody can parse" used to be one answer, and every
    /// getter fell back to its default for both. For no file that is right.
    /// For a broken one it switched analytics back on for somebody who had
    /// turned it off and sent meetings to the cloud for somebody who had
    /// chosen a local engine — and the next write from any window replaced
    /// the whole file with the one key it was changing, which is how a stray
    /// comma would have cost somebody every setting they had.
    enum File {
        case absent
        case parsed([String: Any])
        /// There is a file and it is not a JSON object; the reason is the
        /// parser's own, for the person who has to find the comma.
        case unreadable(reason: String)
    }

    static func file() -> File {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else {
            remembered.keep(nil, for: url)
            return .absent
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
        // An empty file holds no decisions to lose, and refusing to write into
        // one would make `touch config.json` a trap.
        if String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remembered.keep([:], for: url)
            return .parsed([:])
        }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable(reason: "it is not a JSON object")
            }
            remembered.keep(json, for: url)
            return .parsed(json)
        } catch {
            let parser = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            return .unreadable(reason: parser ?? error.localizedDescription)
        }
    }

    /// Why the file cannot be read, or nil when it can — or when there is no
    /// file, which is a perfectly good config.
    static var unreadableReason: String? {
        if case .unreadable(let reason) = file() { return reason }
        return nil
    }

    /// What anything that could send a meeting somewhere throws while the
    /// file cannot be read.
    ///
    /// The whole pipeline after recording waits rather than only the cloud
    /// half of it: which engine is local and whether a summary is wanted are
    /// both answers in the file that cannot be read, and the defaults that
    /// stand in for them are `auto` and on. Recording itself needs none of
    /// that and goes on as normal; the sessions stay in the folder, which is
    /// the queue, and are picked up when the file can be read again.
    struct Unreadable: Error, CustomStringConvertible {
        let reason: String

        var description: String {
            "config.json can't be read (\(reason)) — transcription and summaries wait until it can"
        }
    }

    static func requireReadable() throws {
        if let reason = unreadableReason { throw Unreadable(reason: reason) }
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    ///
    /// While the file cannot be read, every getter answers from the settings
    /// this process last read from it. The defaults used to stand in instead,
    /// and the file is read lazily, minutes into a job that had checked it
    /// at the start: a stray comma saved during a transcription deleted the
    /// audio of somebody who keeps it, sent the summary of somebody who
    /// chose Ollama to the cloud, moved the recordings folder back to
    /// ~/Recordings and switched auto-record on for somebody who had turned
    /// it off. The last settings the file held are what the person actually
    /// decided; the defaults are what they did not.
    ///
    /// The problem is still reported everywhere, writes are still refused,
    /// and nothing that sends a meeting anywhere starts until the file reads
    /// again. A process that has never read the file answers with the
    /// defaults, and the few places where a default would do something
    /// nobody asked for ask `settingsUnknown` first.
    private static func load() -> [String: Any]? {
        switch file() {
        case .absent:
            return nil
        case .parsed(let json):
            return json
        case .unreadable(let reason):
            if let last = remembered.last(for: path) {
                FileHandle.standardError.write(Data(
                    ("warning: \(path.path) is not valid JSON (\(reason)) — going on with the "
                        + "settings last read from it\n").utf8
                ))
                return last.json
            }
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON (\(reason)) — using defaults\n".utf8
            ))
            return nil
        }
    }

    /// Whether the settings are not known at all: the file cannot be read,
    /// and this process never read it while it could be. Every getter is
    /// answering with a default, which for most settings is harmless and for
    /// a few — whether to record on its own, where recordings go — is a
    /// decision the person may well have made the other way.
    static var settingsUnknown: Bool {
        guard case .unreadable = file() else { return false }
        return remembered.last(for: path) == nil
    }

    /// The settings last read from each config file, by path — by path
    /// because a test process has a file per test.
    private static let remembered = Remembered()

    private final class Remembered: @unchecked Sendable {
        /// One reading: the object in the file, or nil for no file at all,
        /// which is a perfectly good config too.
        struct Reading {
            let json: [String: Any]?
        }

        private let lock = NSLock()
        private var readings: [String: Reading] = [:]

        func keep(_ json: [String: Any]?, for url: URL) {
            lock.withLock { readings[url.standardizedFileURL.path] = Reading(json: json) }
        }

        func last(for url: URL) -> Reading? {
            lock.withLock { readings[url.standardizedFileURL.path] }
        }
    }

    // MARK: - writing

    /// The config file as it is on disk, or an empty object when there isn't
    /// one yet. While it cannot be read — which `file()` tells apart — it is
    /// the settings last read from it, the same ones every getter answers
    /// with, or an empty object when there were none. The settings window
    /// reads this to show what has been set, as distinct from what merely
    /// defaults.
    static func raw() -> [String: Any] { load() ?? [:] }

    /// Set (or, with a nil value, clear) one setting, addressed by its path
    /// into the JSON — `["auto_record", "start_delay_seconds"]`.
    ///
    /// Clearing rather than writing the default is deliberate: a config that
    /// only contains what you changed keeps reading as a list of your
    /// decisions, and a default that improves later reaches you instead of
    /// being frozen into your file the first time you opened a window.
    /// Posted after the config file has been written, so that anything on
    /// screen showing a setting can read it again.
    ///
    /// Several surfaces render the same keys — the setup window, both tabs of
    /// the settings window, the status window's live-transcript switch — and
    /// nothing stops two of them being open at once. Without this the one
    /// nobody typed into keeps yesterday's answer until it is reopened, which
    /// looks exactly like the change not having been saved.
    ///
    /// It carries nothing: a listener redraws from the file, which is the
    /// only account of the settings any of them trusts anyway.
    static let didChange = Notification.Name("amanu.config.didChange")

    @discardableResult
    static func update(path: [String], value: Any?) -> Bool {
        guard let first = path.first else { return false }
        // The writing half of `Key`: a setting nothing reads, written by a
        // window, is a setting that silently does nothing.
        assert(Key(rawValue: path.joined(separator: ".")) != nil,
               "\(path.joined(separator: ".")) is not a Config.Key")
        var json: [String: Any]
        switch file() {
        case .absent:
            json = [:]
        case .parsed(let parsed):
            json = parsed
        case .unreadable(let reason):
            // Writing now would mean writing the defaults plus this one key
            // over everything the person has in there. The file is theirs to
            // fix; until then nothing changes it.
            FileHandle.standardError.write(Data(
                ("not changing \(Self.path.path): it can't be read (\(reason)), and "
                    + "writing it now would replace everything in it\n").utf8
            ))
            return false
        }

        if path.count == 1 {
            if let value { json[first] = value } else { json.removeValue(forKey: first) }
        } else {
            var nested = json[first] as? [String: Any] ?? [:]
            nested = updated(nested, path: Array(path.dropFirst()), value: value)
            if nested.isEmpty { json.removeValue(forKey: first) } else { json[first] = nested }
        }
        switch write(json) {
        case .failed: return false
        case .unchanged: return true
        case .written:
            NotificationCenter.default.post(name: didChange, object: nil)
            Analytics.settingChanged(path: path, value: value)
            return true
        }
    }

    /// What a write did, which is not always what it was asked to do.
    private enum WriteResult {
        case written
        case unchanged
        case failed
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

    /// Put the config on disk, unless it is already there.
    ///
    /// The unchanged case is not an optimisation. A field commits when it
    /// loses focus, and focus is lost for reasons that are not edits — a tab
    /// changed, another window taking over, the window closing — so the same
    /// bytes were being written back regularly with nobody having decided
    /// anything. Nothing was lost, but the file's timestamp is the only claim
    /// anyone has that a setting was changed, and it was lying; and since
    /// every write wakes every open window to redraw, a write from inside a
    /// redraw is the start of a loop rather than a wasted syscall.
    private static func write(_ json: [String: Any]) -> WriteResult {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return .failed }
        // Sorted keys and a stable formatter, so identical settings really do
        // produce identical bytes rather than a diff in key order.
        if let current = try? Data(contentsOf: path), current == data { return .unchanged }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: path, options: .atomic)
            return .written
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't write \(path.path): \(error)\n".utf8
            ))
            return .failed
        }
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return Home.current.expanding(cliOverride, isDirectory: true)
        }
        return recordingsDir() ?? defaultRoot
    }
}

private extension String {
    /// Keys read from files and the environment arrive with trailing
    /// newlines more often than not.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
