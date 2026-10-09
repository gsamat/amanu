import AppKit
import FluidAudio
import Foundation

/// Everything a new installation is asked: the permissions macOS will
/// otherwise demand at the worst possible moment, and the choices amanu can't
/// sensibly make for you — what writes the transcript, what writes the
/// summary, where the files go, and whether it all runs by itself.
///
/// It is a form rather than a window because it is shown in two places. The
/// setup window wraps it in a wizard — a footer that names what is left and a
/// button that does the next thing — and the settings window shows the same
/// form as its first tab. One form, so the two can never drift into
/// disagreeing about what amanu offers; and there is nothing in setup a
/// person should have to reopen setup to change.
///
/// It is AppKit rather than a terminal wizard for a reason that isn't
/// cosmetic. macOS grants microphone and system-audio capture to the process
/// that asks; a wizard run from a shell teaches the system that Terminal may
/// record, and the daemon then captures a full-length silent file with nothing
/// to show for it (.issues/rca-002). The asking has to happen here, inside the
/// program that will do the recording.
///
/// Everything it shows is read from the machine rather than assumed: whether a
/// grant exists, whether a model is downloaded, whether `claude` and `codex`
/// are installed *and answer when run*. Nothing here says "should work".
@MainActor
final class SetupForm: NSObject, NSTextFieldDelegate {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// form is worth losing a meeting for.
    var isRecording: (() -> Bool)?
    /// Called whenever anything a host displays *about* the form may have
    /// changed — what is still outstanding, what the next action is. The
    /// setup window's footer is written from it, and the settings window
    /// redraws its other tab.
    var onStateChange: (() -> Void)?

    /// What the config says about transcription, and how to change it.
    ///
    /// The pair is one seam rather than two because the transcription
    /// switches only work as a loop: a click writes the choice and then
    /// redraws the switches from what it wrote. Replacing only the writing
    /// would leave a test watching the form redraw from the config file of
    /// whoever is running the suite — which is also the reason the bug this
    /// pair exists to keep out shipped in the first place.
    var storedTranscription: @MainActor () -> TranscriptionChoice = {
        TranscriptionChoice.read(
            engine: Config.transcriptionEngine(),
            cloudProvider: Config.transcriptionCloudProvider(),
            enabled: Config.transcriptionEnabled(),
            localModels: Platform.supportsLocalModels,
            localEngine: Config.transcriptionLocalEngine())
    }
    var write: @MainActor ([String], Any?) -> Void = { Config.update(path: $0, value: $1) }

    /// Whether the local model is on this Mac, and how to put it there. Also
    /// a seam, for the same reason and one more: the click that has to be
    /// got right is the one made with no model on the disk, and it starts a
    /// download — which a test has to be able to answer without pulling 460
    /// megabytes over the network.
    var parakeetIsHere: @MainActor () -> Bool = {
        let version = ParakeetEngine.configuredVersion()
        return AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }
    var fetchParakeet: @MainActor () async throws -> Void = {
        _ = try await AsrModels.downloadAndLoad(version: ParakeetEngine.configuredVersion())
    }

    /// How a pasted key is put to the service it is for. A seam because the
    /// answer decides what is written where, and a test has to be able to
    /// say "that key works" without a network or a real key — which is the
    /// only way to check that a key for one purpose lands in that purpose's
    /// file and no other.
    var checkKey: @MainActor (Credentials.Check) async -> Credentials.Verdict = { check in
        await check.ask()
    }

    /// The system-audio test: a tone out of the speakers and a tap listening
    /// for it. A seam so a test can prove when it is *not* played without
    /// playing it.
    var playTestTone: @MainActor () async -> SetupPermissions.SystemAudioResult = {
        await SetupPermissions.testSystemAudio()
    }

    /// The form itself, for a host to put in a scroll view.
    let view = FlippedStackView()

    /// Redraws this copy when anything writes the config file — the other
    /// window showing the same form, the Advanced tab beside it, or the
    /// status window's live-transcript switch.
    private var configWatch: ConfigWatch.Token?
    /// Redraws this copy when amanu comes back to the front. Every grant the
    /// Access rows ask for is given somewhere else — System Settings, a
    /// Login Items switch — and the person comes back from there to a window
    /// that went on saying the microphone was denied until something else
    /// happened to redraw it. Coming back is the moment to look again.
    private var activation: ConfigWatch.Token?

    private let launchRow = AccessRow(
        title: localised("Start at login", "Запуск при входе"),
        detail: localised(
            "So a meeting is never missed because nobody opened amanu.",
            "Чтобы встреча не пропала из-за того, что amanu никто не открыл."),
        action: localised("Install", "Включить"),
        grantedNote: localised("installed", "включено"))
    private let micRow = AccessRow(
        title: localised("Microphone", "Микрофон"),
        detail: localised("Your side of the call.", "Ваша сторона разговора."),
        action: localised("Allow", "Разрешить"),
        grantedNote: localised("allowed", "разрешено"))
    private let audioRow = AccessRow(
        title: localised("System audio", "Звук системы"),
        detail: "",
        action: localised("Allow and test", "Разрешить и проверить"),
        grantedNote: localised("heard the tone", "тон услышан"))
    private let calendarRow = AccessRow(
        title: localised("Calendar", "Календарь"),
        detail: localised(
            "Names the folder and the speakers from the invitees.",
            "По участникам события называет папку и говорящих."),
        action: localised("Allow", "Разрешить"),
        grantedNote: localised("allowed", "разрешено"),
        optional: true)

    private let cloudSwitch = NSSwitch()
    private let cloudStatus = NSTextField(labelWithString: "")
    private let providerCards = ChoiceGroup()
    private let cloudKey = NSSecureTextField()
    private let cloudKeyStatus = NSTextField(labelWithString: "")
    /// Shown only when there is a key to paste: an empty field under a
    /// working provider is an invitation to overwrite something that works.
    private let keyLine = NSStackView()
    /// The provider whose key field is open. Set when a card or the switch is
    /// clicked for a service with no key yet — and while it is set, the
    /// provider actually in force is unchanged, so a curious click cannot cost
    /// the next meeting its transcript.
    private var pendingProvider: String?
    /// The provider in force, read back from the config on every refresh.
    private var provider = "assemblyai"
    private let localSwitch = NSSwitch()
    private let localEngineCards = ChoiceGroup()
    private var localDownloadButtons: [String: NSButton] = [:]
    private var localDownloadErrors: [String: String] = [:]

    private let language = NSPopUpButton()
    private let languageNote = NSTextField(labelWithString: "")
    private let keepAudio = NSSwitch()
    private let liveTranscription = NSSwitch()
    private let liveStatus = NSTextField(labelWithString: "")
    private let diarizationSwitch = NSSwitch()
    private let diarizationDetail = SetupLayout.detail("", lines: 2, width: 440)
    private let diarizationCards = ChoiceGroup()
    private var diarizationDownloadButtons: [DiarizationModel: NSButton] = [:]
    private var diarizationDownloadTask: Task<Void, Never>?
    private var downloadingDiarizationModel: DiarizationModel?
    private var diarizationProgress: [DiarizationModel: Double] = [:]
    private var diarizationErrors: [DiarizationModel: String] = [:]
    var fetchDiarization: @MainActor (DiarizationModel, @escaping @Sendable (Double) -> Void) async throws -> Void = {
        model, progress in
        try await DiarizationModelStore.shared(for: model).download(progress: progress)
    }
    private let liveModelStore = LiveTranscriptionModelStore()
    /// What the models on this Mac weigh, for the two rows that say so. The
    /// figure in each row's prose is what a download will cost; this is what
    /// it did cost, and only this one can be trusted once the files exist.
    private let modelStorage = ModelStorage()
    private let whisperModelStore = WhisperModelStore()
    private let gigaAMModelStore = GigaAMModelStore()
    private var whisperDownloadTask: Task<Void, Never>?
    private var gigaAMDownloadTask: Task<Void, Never>?
    private var liveDownloadTask: Task<Void, Never>?
    private var liveDownloading = false
    /// What parakeet weighs on disk once it is there — measured, not quoted:
    /// 461 MB for v3, and v2 is the same 0.6B model. The bar is the cache
    /// directory growing towards this number, so a figure taken from
    /// somewhere else is a bar that stops three quarters of the way and a
    /// count that never reaches what it promised.
    private static let parakeetMegabytes = 460

    private let parakeetStatus = NSTextField(labelWithString: "")
    private let parakeetBar = NSProgressIndicator()
    /// The bar's clock, which is only worth running while somebody can see
    /// the bar.
    private var parakeetProgress: Timer?
    /// The download itself, which is not the same thing as its bar. It used
    /// not to be kept at all: closing the window stopped the timer, the form
    /// took that to mean nothing was downloading, and opening it again
    /// offered a second fetch of the same 460 megabytes into the same cache
    /// while the first was still running.
    private var parakeetDownload: Task<Void, Never>?

    private let summariesOn = NSSwitch()
    private let summaryCards = ChoiceGroup()
    private let keyProvider = NSSegmentedControl(
        labels: ["OpenAI", "Anthropic", "OpenAI-compatible"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let summaryKey = NSSecureTextField()
    private let summaryKeyStatus = NSTextField(labelWithString: "")
    private let summaryOpenAIBaseURL = NSTextField()
    private let summaryOpenAIModel = NSTextField()
    private let summaryOpenAIOptions = NSStackView()
    private var summaryOpenAIBaseURLRow: NSView?
    private let summaryOllamaBaseURL = NSTextField()
    private let summaryOllamaModel = NSTextField()
    private lazy var summaryKeyLink = link(
        localised("Get a key", "Получить ключ"),
        "https://console.anthropic.com/settings/keys")

    private let recordingsPath = NSTextField(labelWithString: "")
    private let menuBarIcon = NSSwitch()
    private let dockIcon = NSSwitch()
    /// Says what is left when both icons are off. Present only then: it is a
    /// consequence, not a warning, and a line explaining how to get back to a
    /// window you are looking at is noise until it is the only way.
    private let noIconsNote: NSTextField = {
        let label = SetupLayout.status()
        label.lineBreakMode = .byWordWrapping
        // Three, though two is enough in both languages at the width the
        // setup window opens at: the settings window is narrower, and a
        // sentence that is the only way back into the program is the last one
        // that should end in an ellipsis.
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 520
        return label
    }()
    private let autoRecord = NSSwitch()
    private let analytics = NSSwitch()

    /// What is wrong with the config file, above everything else in the form:
    /// while it stands, the switches below show defaults rather than the
    /// file, and none of them can be saved. See `Config.Problem`.
    private let configProblems: NSTextField = {
        let label = SetupLayout.status()
        label.textColor = .systemOrange
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 520
        label.isHidden = true
        return label
    }()

    /// False where the host says the same thing itself — the settings window,
    /// whose footer sits under this form and under the Advanced tab alike.
    var showsConfigProblems = true {
        didSet { refresh() }
    }

    /// What the last look for `claude`, `codex` and ollama found, by card.
    /// Empty until that look finishes, and a missing answer is not "absent":
    /// the window says nothing about a tool it has not been to see yet.
    private var summaryToolRuns: [String: Bool] = [:]


    override init() {
        super.init()

        let form = view
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = SetupLayout.sectionGap
        form.edgeInsets = NSEdgeInsets(
            top: 22, left: SetupLayout.gutter, bottom: 22, right: SetupLayout.gutter)

        launchRow.identifier = NSUserInterfaceItemIdentifier("access.login")
        micRow.identifier = NSUserInterfaceItemIdentifier("access.microphone")
        audioRow.identifier = NSUserInterfaceItemIdentifier("access.system-audio")
        calendarRow.identifier = NSUserInterfaceItemIdentifier("access.calendar")
        form.addArrangedSubview(configProblems)
        form.addArrangedSubview(SetupLayout.section(
            localised("Access", "Доступ"),
            content: SetupLayout.box([launchRow, micRow, audioRow, calendarRow])))

        var transcription: [NSView] = [
            transcriptionRows(),
            SetupLayout.section(localised("Diarization", "Диаризация"),
                                content: SetupLayout.box([diarizationRow()])),
            languageRow(),
        ]
        // The live transcript is a local streaming model, so on an Intel Mac
        // there is nothing behind the switch. Left out rather than shown
        // switched off: an offer that can never be accepted.
        if Platform.supportsLocalModels {
            transcription.append(SetupLayout.box([liveTranscriptionRow()]))
        }
        form.addArrangedSubview(SetupLayout.section(
            localised("Transcription", "Расшифровка"),
            content: SetupLayout.group(transcription)))

        form.addArrangedSubview(SetupLayout.section(
            localised("Files", "Файлы"),
            content: SetupLayout.box([folderRow(), keepAudioRow()])))

        form.addArrangedSubview(SetupLayout.section(
            localised("Summaries", "Саммари"),
            leading: summariesOn,
            content: summaryChoices()))

        form.addArrangedSubview(SetupLayout.section(
            localised("Where amanu shows up", "Где видно amanu"),
            content: SetupLayout.group(
                [SetupLayout.box([menuBarIconRow(), dockIconRow()]), noIconsNote],
                spacing: SetupLayout.headerGap)))

        // No heading of its own: one switch is not a section, and it belongs
        // at the end because it is the thing that makes all of the above run
        // without anyone opening this form again.
        form.addArrangedSubview(SetupLayout.box([autoRecordRow()]))

        // Last in the form so the default-on reporting choice is visible on
        // first setup and remains easy to change when setup is reopened.
        form.addArrangedSubview(SetupLayout.box([analyticsRow()]))

        for view in form.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: form.widthAnchor, constant: -2 * SetupLayout.gutter).isActive = true
        }

        // Names for the switches that do not depend on the words beside
        // them, so a test can find a switch without walking up from its
        // label through however many stacks the layout has this week.
        for (toggle, name) in [
            (cloudSwitch, "transcription.cloud"), (localSwitch, "transcription.local"),
            (liveTranscription, "transcription.live"),
            (diarizationSwitch, "transcription.local-diarization"),
            (keepAudio, "files.keep-audio"),
            (summariesOn, "summary.enabled"), (menuBarIcon, "icons.menu-bar"),
            (dockIcon, "icons.dock"), (autoRecord, "auto-record"), (analytics, "analytics"),
        ] {
            toggle.identifier = NSUserInterfaceItemIdentifier(name)
        }
        wireActions()
        refresh()
        configWatch = ConfigWatch.observe { [weak self] in self?.refresh() }
        // A token of the same kind as the config watch's: it ends the
        // observation when the form goes.
        activation = ConfigWatch.Token(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    /// Only a form somebody can see: asking whether a login item is
    /// registered is a round trip to another daemon, and a window that is
    /// closed will be redrawn by `reload` when it opens anyway.
    func cameBack() {
        guard view.window?.isVisible == true else { return }
        refresh()
    }

    /// Re-read the machine and the config file. A host calls this when the
    /// form comes back on screen: the menu and the status window both write
    /// `auto_record.enabled`, and a form showing yesterday's answer is worse
    /// than no form at all.
    func reload() {
        if parakeetDownload != nil, parakeetProgress == nil { watchParakeetSize() }
        refresh()
        // Detection runs off the main thread: finding `claude` can mean
        // starting the login shell, and a form that freezes while it asks
        // would be a worse first impression than one that fills in.
        Task { await detectTools() }
    }

    /// Put down what outlives a keystroke. The setup window calls it on the
    /// way out: a timer polling a download directory has no reason to keep
    /// running behind a closed window.
    ///
    /// The parakeet download itself is left running: FluidAudio offers no way
    /// to stop one partway, and a bar put away is not a download abandoned.
    /// `reload` puts the bar back.
    func stop() {
        parakeetProgress?.invalidate()
        parakeetProgress = nil
        whisperDownloadTask?.cancel()
        whisperDownloadTask = nil
        gigaAMDownloadTask?.cancel()
        gigaAMDownloadTask = nil
    }
    // MARK: - building

    /// The two questions this section actually asks: may audio leave this
    /// Mac, and should the local model be kept ready. Both are switches, and
    /// neither is a fallback setting — "the cloud when it answers, this Mac
    /// when it doesn't" is what having both on *means*, not a third option to
    /// pick.
    ///
    /// The provider cards sit under the cloud switch and stay on screen while
    /// it is off, because they are what the switch costs: the price per hour
    /// belongs where the decision is made, not in a document.
    private func transcriptionRows() -> NSView {
        cloudSwitch.target = self
        cloudSwitch.action = #selector(cloudToggled)
        cloudStatus.font = SetupLayout.statusFont
        cloudStatus.textColor = .secondaryLabelColor
        cloudStatus.lineBreakMode = .byTruncatingTail

        let cloudRow = SetupLayout.row(
            leading: cloudSwitch,
            title: SetupLayout.title(localised("In the cloud", "В облаке")),
            detail: SetupLayout.detail(
                localised(
                    "Audio is uploaded to the provider's servers. Better on Russian, "
                        + "and tells apart multiple speakers.",
                    "Звук уходит на серверы провайдера. Лучше слышит русский "
                        + "и различает нескольких говорящих."),
                lines: 2, width: 440),
            trailing: [cloudStatus])

        localSwitch.target = self
        localSwitch.action = #selector(localToggled)
        let localChoices = [
            ("parakeet", "Parakeet v3", localised(
                "Fastest · about \(Self.parakeetMegabytes) MB",
                "Самая быстрая · около \(Self.parakeetMegabytes) МБ")),
            ("whisper", "Whisper large-v3-turbo", localised(
                "Best multilingual accuracy · about 550 MB",
                "Лучшая точность на разных языках · около 550 МБ")),
            ("gigaam", "GigaAM v3", localised(
                "Alternative for Russian · about 260 MB",
                "Альтернатива для русского · около 260 МБ")),
        ]
        let localCards = localChoices.map { id, title, detail in
            let download = SetupLayout.actionButton(
                localised("Download…", "Скачать…"),
                target: self,
                action: #selector(downloadLocalClicked(_:)))
            download.identifier = NSUserInterfaceItemIdentifier("transcription.download.\(id)")
            localDownloadButtons[id] = download
            return ChoiceCard(id: id, title: title, detail: detail, accessories: [download])
        }
        localEngineCards.adopt(localCards)
        localEngineCards.onChange = { [weak self] id in self?.localEnginePicked(id) }
        parakeetStatus.font = SetupLayout.statusFont
        parakeetStatus.textColor = .secondaryLabelColor
        parakeetStatus.lineBreakMode = .byTruncatingTail
        parakeetStatus.isHidden = true
        // FluidAudio reports no progress, so the bar is the cache directory
        // growing towards the model's known size. Approximate, and better
        // than a spinner that could mean anything.
        parakeetBar.style = .bar
        parakeetBar.isIndeterminate = false
        parakeetBar.controlSize = .small
        parakeetBar.minValue = 0
        parakeetBar.maxValue = Double(Self.parakeetMegabytes)
        parakeetBar.isHidden = true
        parakeetBar.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let localRow = SetupLayout.row(
            leading: localSwitch,
            title: SetupLayout.title(localised("On this Mac", "На этом маке")),
            detail: SetupLayout.detail(
                localised(
                    "Nothing leaves the machine; local transcripts label speakers as me / them.",
                    "С мака ничего не уходит; локальные расшифровки помечают спикеров как «я»/«они»."),
                lines: 2, width: 440),
            trailing: [])

        let progress = NSStackView(views: [parakeetBar, parakeetStatus, NSView()])
        progress.orientation = .horizontal
        progress.alignment = .centerY
        progress.spacing = 8

        let localOptions = NSStackView(views: [SetupLayout.cards(localEngineCards.cards), progress])
        localOptions.orientation = .vertical
        localOptions.alignment = .leading
        localOptions.spacing = 9
        localOptions.edgeInsets = NSEdgeInsets(top: 0, left: 58, bottom: 13, right: 14)
        for option in localOptions.arrangedSubviews {
            option.widthAnchor.constraint(
                equalTo: localOptions.widthAnchor, constant: -72).isActive = true
        }

        let localBlock = NSStackView(views: [localRow, localOptions])
        localBlock.orientation = .vertical
        localBlock.alignment = .leading
        localBlock.spacing = 0
        for row in localBlock.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: localBlock.widthAnchor).isActive = true
        }

        // One row, not two, on an Intel Mac: there is no local model to offer,
        // and the row explains itself rather than vanishing.
        return SetupLayout.box([cloudRow, providerRow(), localBlock])
    }

    /// The provider cards and the one key field they share, indented under
    /// the switch they belong to.
    private func providerRow() -> NSView {
        let assembly = ChoiceCard(
            id: "assemblyai",
            title: "AssemblyAI",
            detail: localised(
                "$0.23 an hour. No limit on meeting length.",
                "$0,23 за час. Без ограничения на длину встречи."),
            accessories: [link(
                localised("Get a key", "Получить ключ"),
                "https://www.assemblyai.com/dashboard/signup")])
        let openai = ChoiceCard(
            id: "openai",
            title: "OpenAI",
            detail: localised(
                "$0.36 an hour. Same key as summaries.",
                "$0,36 за час. Тот же ключ, что и для саммари."),
            accessories: [link(
                localised("Get a key", "Получить ключ"),
                "https://platform.openai.com/api-keys")])
        let elevenlabs = ChoiceCard(
            id: "elevenlabs",
            title: "ElevenLabs",
            detail: localised(
                "Scribe v2. $0.44 an hour for a two-channel call.",
                "Scribe v2. $0,44 за час разговора с двумя каналами."),
            accessories: [link(
                localised("Get a key", "Получить ключ"),
                "https://elevenlabs.io/app/developers/api-keys")])
        providerCards.adopt([assembly, openai, elevenlabs])
        providerCards.onChange = { [weak self] id in self?.providerPicked(id) }

        cloudKey.placeholderString = localised("paste key", "вставьте ключ")
        cloudKey.identifier = NSUserInterfaceItemIdentifier("transcription.key")
        cloudKeyStatus.identifier = NSUserInterfaceItemIdentifier("transcription.key.status")
        cloudKey.font = SetupLayout.detailFont
        cloudKey.delegate = self
        cloudKey.widthAnchor.constraint(equalToConstant: 220).isActive = true
        cloudKeyStatus.font = SetupLayout.statusFont
        cloudKeyStatus.textColor = .secondaryLabelColor
        cloudKeyStatus.lineBreakMode = .byWordWrapping
        cloudKeyStatus.maximumNumberOfLines = 2

        keyLine.orientation = .horizontal
        keyLine.alignment = .centerY
        keyLine.spacing = 10
        keyLine.setViews([cloudKey, cloudKeyStatus, NSView()], in: .leading)

        let stack = NSStackView(views: [SetupLayout.cards(providerCards.cards), keyLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // Indented to the width of a switch plus its gap, so the cards read as
        // the cloud row's detail rather than as a third choice beside it.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 58, bottom: 13, right: 14)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -72).isActive = true
        }
        return stack
    }

    /// A menu rather than the two-letter code this used to ask for. The code
    /// was never a question anybody could answer from the window: nothing said
    /// whether it wanted `ru`, `rus` or `ru-RU`, and a typo went to stderr,
    /// where nobody was reading. What is stored is still the code.
    private func languageRow() -> NSView {
        let label = NSTextField(labelWithString: localised(
            "Meetings are mostly in", "Чаще всего встречи на языке"))
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor

        language.target = self
        language.action = #selector(languageChanged)
        language.identifier = NSUserInterfaceItemIdentifier("transcription.language")
        language.setAccessibilityLabel(label.stringValue)
        buildLanguageMenu()

        let picker = NSStackView(views: [label, language, NSView()])
        picker.orientation = .horizontal
        picker.alignment = .centerY
        picker.spacing = 10

        languageNote.font = SetupLayout.statusFont
        languageNote.textColor = .secondaryLabelColor
        languageNote.lineBreakMode = .byWordWrapping
        languageNote.maximumNumberOfLines = 2
        languageNote.preferredMaxLayoutWidth = 520

        let stack = NSStackView(views: [picker, languageNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// Detect first, then the five languages amanu is actually used in, then
    /// the alphabet. Each item carries its own config value, so the menu can
    /// be reordered without a table of indices to keep in step with it.
    private func buildLanguageMenu() {
        let menu = NSMenu()
        let detect = NSMenuItem(
            title: localised("Detect automatically", "Определять автоматически"),
            action: nil, keyEquivalent: "")
        menu.addItem(detect)
        menu.addItem(.separator())
        for (index, choice) in MeetingLanguages.menu.enumerated() {
            if index == MeetingLanguages.pinned.count { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")
            item.representedObject = choice.code
            menu.addItem(item)
        }
        language.menu = menu
    }

    private var selectedLanguage: String? {
        language.selectedItem?.representedObject as? String
    }

    private func liveTranscriptionRow() -> NSView {
        liveTranscription.target = self
        liveTranscription.action = #selector(liveTranscriptionToggled)
        liveStatus.font = SetupLayout.statusFont
        liveStatus.textColor = .secondaryLabelColor
        liveStatus.lineBreakMode = .byTruncatingTail

        return SetupLayout.row(
            leading: liveTranscription,
            title: SetupLayout.title(localised(
                "I want a live transcript during meetings",
                "Показывать расшифровку прямо во время встречи")),
            detail: SetupLayout.detail(
                localised(
                    "A 600 MB NVIDIA model downloads once. Nothing leaves this Mac, "
                        + "and the final transcript is still parakeet's.",
                    "Один раз скачается модель NVIDIA, 600 МБ. С мака ничего не уходит, "
                        + "итоговую расшифровку всё равно делает parakeet."),
                lines: 2, width: 520),
            trailing: [liveStatus])
    }

    private func diarizationRow() -> NSView {
        diarizationSwitch.target = self
        diarizationSwitch.action = #selector(diarizationToggled)
        let cards = DiarizationModel.allCases.map { model in
            let download = SetupLayout.actionButton(
                localised("Download…", "Скачать…"), target: self,
                action: #selector(downloadDiarizationClicked(_:)))
            download.identifier = .init("transcription.diarization.download.\(model.rawValue)")
            diarizationDownloadButtons[model] = download
            let size = Int((Double(model.advertisedBytes)
                / (model == .community1 ? 1_048_576 : 1_000_000)).rounded())
            let detail = localised(
                "(\(model.detailEnglish))\n\(model == .nemotron3 ? "Recommended · " : "")about \(size) MB",
                "(\(model.detailRussian))\n\(model == .nemotron3 ? "Рекомендуется · " : "")около \(size) МБ")
            let card = ChoiceCard(id: "diarization.\(model.rawValue)", title: model.title,
                                  detail: detail, accessories: [download])
            return card
        }
        diarizationCards.adopt(cards)
        diarizationCards.onChange = { [weak self] id in self?.diarizationModelPicked(id) }
        let row = SetupLayout.row(
            leading: diarizationSwitch,
            title: SetupLayout.title(localised(
                "Separate speakers", "Разделять говорящих")),
            detail: diarizationDetail)
        let options = NSStackView(views: [SetupLayout.cards(diarizationCards.cards)])
        options.orientation = .vertical
        options.alignment = .leading
        options.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        options.arrangedSubviews[0].widthAnchor.constraint(
            equalTo: options.widthAnchor, constant: -20).isActive = true
        let block = NSStackView(views: [row, options])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 0
        row.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        options.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        return block
    }

    @objc private func diarizationToggled() {
        guard Platform.supportsLocalModels, transcriptionChoice.local,
              Config.problems().isEmpty else { refreshDiarization(); return }
        let enabled = diarizationSwitch.state == .on
        write(["transcription", "local_diarization"], enabled ? true : nil)
        refresh()
    }

    private func diarizationModelPicked(_ id: String) {
        guard let model = DiarizationModel(rawValue: String(id.dropFirst("diarization.".count))),
              diarizationSwitch.isEnabled, diarizationSwitch.state == .on,
              diarizationCards.card(id)?.isEnabled == true else { refreshDiarization(); return }
        write(["transcription", "diarization_model"], model.rawValue)
        refresh()
    }

    @objc private func downloadDiarizationClicked(_ sender: NSButton) {
        let prefix = "transcription.diarization.download."
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix(prefix),
              let model = DiarizationModel(rawValue: String(raw.dropFirst(prefix.count))),
              sender.isEnabled, diarizationDownloadTask == nil else { return }
        diarizationErrors[model] = nil
        diarizationProgress[model] = 0
        downloadingDiarizationModel = model
        diarizationDownloadTask = Task { [weak self, model] in
            guard let self else { return }
            do {
                try await fetchDiarization(model) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadingDiarizationModel == model else { return }
                        self.diarizationProgress[model] = max(self.diarizationProgress[model] ?? 0, fraction)
                        self.refreshDiarization()
                    }
                }
            } catch {
                diarizationErrors[model] = error.localizedDescription
            }
            diarizationDownloadTask = nil
            downloadingDiarizationModel = nil
            diarizationProgress[model] = nil
            refreshDiarization()
        }
        refreshDiarization()
    }

    private func refreshDiarization() {
        let localAvailable = Platform.supportsLocalModels && transcriptionChoice.local
            && Config.problems().isEmpty
        diarizationSwitch.isEnabled = localAvailable
        diarizationSwitch.state = Config.localDiarizationEnabled() ? .on : .off
        diarizationDetail.stringValue = !Platform.supportsLocalModels
            ? localised("Needs Apple Silicon.", "Нужен Apple Silicon.")
            : transcriptionChoice.local
            ? localised("After local transcription. Audio stays on this Mac.",
                        "После локальной расшифровки. Звук остаётся на этом маке.")
            : localised("Available with On this Mac enabled.",
                        "Доступно при включённом «На этом Mac».")
        diarizationSwitch.setAccessibilityHelp(diarizationDetail.stringValue)
        diarizationCards.select("diarization.\(Config.diarizationModel().rawValue)")
        let enabled = localAvailable && diarizationSwitch.state == .on
        for model in DiarizationModel.allCases {
            let card = diarizationCards.card("diarization.\(model.rawValue)")
            let button = diarizationDownloadButtons[model]
            let ready = DiarizationModelStore.isReady(
                at: DiarizationModelStore.shared(for: model).directory, model: model)
            card?.isEnabled = enabled
            button?.isEnabled = enabled && diarizationDownloadTask == nil && !ready
            button?.isHidden = ready || downloadingDiarizationModel == model
            button?.title = diarizationErrors[model] == nil
                ? localised("Download…", "Скачать…")
                : localised("Retry…", "Повторить…")
            if downloadingDiarizationModel == model {
                card?.report(localised("downloading · ", "загрузка · ")
                    + "\(Int((diarizationProgress[model] ?? 0) * 100))%")
            } else if ready {
                card?.report(localised("ready · ", "готова · ")
                    + ModelStorage.describe(bytes: modelStorage.diarizationModel(model).bytes), good: true)
            } else if let error = diarizationErrors[model] {
                card?.report(localised("download failed: ", "ошибка загрузки: ") + error)
            } else if !Platform.supportsLocalModels {
                card?.report(localised("needs Apple Silicon", "нужен Apple Silicon"))
            } else {
                card?.report("")
            }
        }
    }

    /// Where the recordings live, and the one thing worth saying about the
    /// default: it is outside Documents, Desktop and Downloads, so macOS never
    /// has to ask a background recorder for permission to write there.
    private func folderRow() -> NSView {
        recordingsPath.font = SetupLayout.monoFont
        recordingsPath.lineBreakMode = .byTruncatingMiddle

        folderDetail.stringValue = Self.folderAdvice
        return SetupLayout.row(
            symbol: "folder",
            title: recordingsPath,
            detail: folderDetail,
            trailing: [SetupLayout.actionButton(
                localised("Choose…", "Выбрать…"),
                target: self, action: #selector(chooseFolder))])
    }

    /// What the line under the folder says, until a folder is chosen during
    /// a recording and it has something more pressing to say.
    private static var folderAdvice: String {
        localised(
            "Outside Documents and Desktop, so macOS never has to ask.",
            "Вне Документов и Рабочего стола — macOS не будет спрашивать.")
    }

    private let folderDetail = SetupLayout.detail("", lines: 2)

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.resolveRoot(cliOverride: nil)
        panel.prompt = localised("Use folder", "Выбрать папку")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Store it the way a person would write it: a path under the home
        // directory stays readable, and stays right if the account is renamed.
        Config.update(path: ["recordings_dir"], value: Home.current.abbreviating(chosen.path))
        // Taken up at once when nothing is recording; a recording running now
        // finishes in the folder it started in, and that is worth saying
        // before somebody goes looking for it in the new one.
        folderDetail.stringValue = isRecording?() == true
            ? localised(
                "The recording in progress stays in the old folder; the next one goes here.",
                "Идущая запись останется в старой папке, следующая ляжет сюда.")
            : Self.folderAdvice
        refresh()
    }

    /// The one checkbox in a window of switches, and the only row whose words
    /// did not start where the words above them started — the checkbox stood
    /// in the column the folder symbol uses, and its title six points to the
    /// left of the path's. It is a switch now, and its label still toggles it.
    private func keepAudioRow() -> NSView {
        keepAudio.target = self
        keepAudio.action = #selector(keepAudioChanged)
        return SetupLayout.row(
            symbol: "waveform",
            title: SetupLayout.title(localised(
                "Keep the audio after transcribing", "Оставлять звук после расшифровки")),
            trailing: [keepAudio])
    }

    private func summaryChoices() -> NSView {
        let claude = ChoiceCard(
            id: "claude-cli",
            title: "Claude Code",
            detail: localised(
                "On the subscription you're already signed into. No key.",
                "По подписке, в которую вы уже вошли. Ключ не нужен."),
            accessories: [link(
                localised("Install it", "Установить"),
                "https://claude.com/product/claude-code")])
        let codex = ChoiceCard(
            id: "codex-cli",
            title: "Codex",
            detail: localised(
                "Same deal, on your OpenAI subscription.",
                "То же самое, но по подписке OpenAI."),
            accessories: [link(
                localised("Install it", "Установить"),
                "https://developers.openai.com/codex/cli/")])

        // Without this the switch still slides when you push it — NSSwitch
        // animates itself — while nothing at all happens: the choice is never
        // written, the cards below stay live, and every meeting is summarised
        // by a program the person just told to stop. It went unwired from the
        // day the section was built, because the only check for it was a
        // manual one nobody had run.
        summariesOn.target = self
        summariesOn.action = #selector(summariesToggled)

        keyProvider.selectedSegment = 1
        keyProvider.target = self
        keyProvider.action = #selector(keyProviderChanged)
        summaryKey.placeholderString = "sk-ant-…"
        summaryKey.identifier = NSUserInterfaceItemIdentifier("summary.key")
        summaryKeyStatus.identifier = NSUserInterfaceItemIdentifier("summary.key.status")
        summaryKey.font = SetupLayout.detailFont
        summaryKey.delegate = self
        summaryKeyStatus.font = SetupLayout.statusFont
        summaryKeyStatus.textColor = .secondaryLabelColor
        summaryKeyStatus.lineBreakMode = .byWordWrapping
        summaryKeyStatus.maximumNumberOfLines = 2
        configureSummaryField(summaryOpenAIBaseURL, id: "summary.openai_base_url")
        configureSummaryField(summaryOpenAIModel, id: "summary.openai_model")
        summaryOpenAIOptions.orientation = .vertical
        summaryOpenAIOptions.alignment = .leading
        summaryOpenAIOptions.spacing = 6
        let baseURLRow = summaryFieldRow(localised("Base URL", "URL сервера"), summaryOpenAIBaseURL)
        summaryOpenAIBaseURLRow = baseURLRow
        summaryOpenAIOptions.addArrangedSubview(baseURLRow)
        summaryOpenAIOptions.addArrangedSubview(summaryFieldRow(
            localised("Model", "Модель"), summaryOpenAIModel))
        let key = ChoiceCard(
            id: "api-key",
            title: localised("My own key", "Свой ключ"),
            detail: localised(
                "Billed per meeting, needs no CLI.",
                "Оплата за встречу, без CLI."),
            accessories: [keyProvider, summaryKey, summaryOpenAIOptions,
                          summaryKeyStatus, summaryKeyLink])

        // Ollama is a fallback, not a fourth peer: a whole card beside the
        // three real choices reads as a recommendation, and its summaries are
        // the weakest of the four. One slim row keeps it choosable and says so.
        configureSummaryField(summaryOllamaBaseURL, id: "summary.ollama_base_url")
        configureSummaryField(summaryOllamaModel, id: "summary.ollama_model")
        let ollamaOptions = NSStackView(views: [
            summaryFieldRow(localised("Base URL", "URL сервера"), summaryOllamaBaseURL),
            summaryFieldRow(localised("Model", "Модель"), summaryOllamaModel),
        ])
        ollamaOptions.orientation = .vertical
        ollamaOptions.alignment = .leading
        ollamaOptions.spacing = 6
        let ollama = ChoiceCard(
            id: "ollama",
            title: "Ollama",
            detail: localised(
                "Local by default. A remote URL sends the transcript there.",
                "По умолчанию локально. Удалённый URL получит расшифровку."),
            accessories: [
                ollamaOptions,
                link(
                localised("Install Ollama", "Установить Ollama"),
                "https://ollama.com/download/mac")])

        summaryCards.adopt([claude, codex, key, ollama])
        summaryCards.onChange = { [weak self] id in
            guard let self else { return }
            Config.update(path: ["summary", "backend"], value: SetupSelection.summaryBackend(
                choice: id, keyBackend: self.selectedKeyBackend))
            self.refresh()
        }
        let disclosure = SetupLayout.detail(
            localised(
                "Claude, Codex and API models receive meeting content. Ollama stays on this Mac only with a localhost URL.",
                "Claude, Codex и API-модели получают данные встречи. Ollama остаётся на этом маке только с localhost URL."),
            lines: 2,
            width: 520)
        return SetupLayout.group(
            [SetupLayout.cards([claude, codex, key]), ollama, disclosure],
            spacing: SetupLayout.cardGap)
    }

    /// The two places a person can find a running amanu, each of which can be
    /// given up. Both, if they like: what is left then is the program itself,
    /// which is opened the way any program is opened, and `noIconsNote` says
    /// so at the moment it becomes true.
    private func menuBarIconRow() -> NSView {
        menuBarIcon.target = self
        menuBarIcon.action = #selector(iconsChanged)
        return SetupLayout.row(
            leading: menuBarIcon,
            title: SetupLayout.title(localised("In the menu bar", "В строке меню")),
            detail: SetupLayout.detail(
                localised(
                    "The feather, with the clock beside it while a meeting records — and the "
                        + "menu with everything in it.",
                    "Перо, во время встречи рядом с ним часы, и меню со всем остальным."),
                lines: 2, width: 520))
    }

    private func dockIconRow() -> NSView {
        dockIcon.target = self
        dockIcon.action = #selector(iconsChanged)
        return SetupLayout.row(
            leading: dockIcon,
            title: SetupLayout.title(localised("In the Dock", "В доке")),
            detail: SetupLayout.detail(
                localised(
                    "And in ⌘-Tab. The Dock cannot run out of room the way the menu bar can, "
                        + "and clicking the icon shows the window.",
                    "И в ⌘-Tab. В доке, в отличие от строки меню, место не кончается, "
                        + "а по щелчку значка открывается окно."),
                lines: 2, width: 520))
    }

    private func autoRecordRow() -> NSView {
        autoRecord.target = self
        autoRecord.action = #selector(autoRecordToggled)
        return SetupLayout.row(
            leading: autoRecord,
            title: SetupLayout.title(localised(
                "Start recording automatically when a call app takes the mic",
                "Начинать запись, когда приложение звонка берёт микрофон")),
            detail: SetupLayout.detail(
                localised(
                    "And stop when it lets go. A call shorter than 45 seconds is thrown away.",
                    "И заканчивать, когда отпустит. Звонок короче 45 секунд выбрасывается."),
                lines: 2, width: 520))
    }

    private func analyticsRow() -> NSView {
        analytics.target = self
        analytics.action = #selector(analyticsToggled)
        return SetupLayout.row(
            leading: analytics,
            title: SetupLayout.title(localised(
                "Send usage statistics",
                "Отправлять статистику об использовании")),
            detail: SetupLayout.detail(
                localised(
                    "Feature usage with a random installation identifier; no meeting content.",
                    "Использование функций со случайным идентификатором установки; без содержимого встреч."),
                lines: 2, width: 520),
            trailing: [link(
                localised("What exactly", "Что именно"),
                "https://github.com/gsamat/amanu/blob/master/docs/analytics.md")])
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    /// What is left when neither icon is on, and nothing at all while either
    /// is. Static and free of AppKit so the sentence can be checked without a
    /// window: it is the only instruction amanu gives for reaching itself,
    /// and it is shown exactly when it is the only way in.
    nonisolated static func noIconsNote(menuBar: Bool, dock: Bool) -> String {
        guard !menuBar, !dock else { return "" }
        return localised(
            "amanu keeps recording with no icon anywhere. To bring the window back, open Amanu "
                + "again — from Spotlight, or from Applications.",
            "amanu продолжит записывать, но её нигде не будет видно. Чтобы вернуть окно, "
                + "откройте Amanu ещё раз — из Spotlight или из папки «Программы».")
    }

    /// "18 Aug" — enough to tell this week from last spring, and short enough
    /// to sit beside a row title.
    ///
    /// Built on each use rather than once. A `static let` is made the first
    /// time anything asks for it and keeps whatever language was in force
    /// then — which is right in a program that settles its language at
    /// startup and wrong the moment anything else changes it, and a formatter
    /// that is right by luck is worth less than one that is right by
    /// construction. Two rows a person opens a window to read is not a rate
    /// worth caching for.
    private static var day: DateFormatter {
        let formatter = DateFormatter()
        // The window's language, on the Mac's own region: a Russian window
        // saying "heard the tone · 19 Aug" is two languages in one line, and
        // a locale built from the language alone would take the day and month
        // out of the order this Mac writes them in as well.
        var locale = Locale.Components(locale: .current)
        locale.languageComponents.languageCode = .init(InterfaceLanguage.current.rawValue)
        formatter.locale = Locale(components: locale)
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }

    // MARK: - actions

    private func wireActions() {
        launchRow.onAct = { [weak self] in self?.startAtLogin() }
        micRow.onAct = { [weak self] in Task { await self?.askMicrophone() } }
        audioRow.onAct = { [weak self] in Task { await self?.testSystemAudio() } }
        calendarRow.onAct = { [weak self] in Task { await self?.askCalendar() } }
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Written the moment they are clicked, and taken up the moment they are
    /// written — the app reads the same file change and moves its icons. So
    /// the switch that has just emptied the menu bar is on screen beside the
    /// evidence of it, which is what makes turning both off a safe thing to
    /// let anyone do.
    ///
    /// One action for both switches, because `Config.update` writes only what
    /// differs: the half nobody touched costs a comparison and leaves the
    /// file, and its timestamp, alone.
    @objc private func iconsChanged() {
        Config.update(path: ["menu_bar_icon"], value: menuBarIcon.state == .on ? nil : false)
        Config.update(path: ["dock_icon"], value: dockIcon.state == .on ? nil : false)
    }

    @objc private func keepAudioChanged() {
        Config.update(path: ["keep_audio"], value: keepAudio.state == .on ? true : nil)
    }

    /// The cloud switch. Turning it on for a service with no key does not
    /// turn it on: it opens the key field instead and leaves the switch where
    /// it was, because a switch that says "on" while every transcript fails
    /// with HTTP 401 is a lie the person only finds out about after a meeting.
    @objc private func cloudToggled() {
        if cloudSwitch.state == .on, !Credentials.hasTranscriptionKey(for: provider) {
            pendingProvider = provider
            cloudSwitch.state = .off
            refresh()
            focusKeyField()
            return
        }
        pendingProvider = nil
        commitTranscription()
    }

    /// Picking a card is how you say "use this one", so a card with a working
    /// key also switches the cloud on. A card without one only opens the key
    /// field: what is in force stays in force until the new key is accepted.
    private func providerPicked(_ id: String) {
        guard Credentials.hasTranscriptionKey(for: id) else {
            pendingProvider = id
            refresh()
            focusKeyField()
            return
        }
        pendingProvider = nil
        provider = id
        cloudSwitch.state = .on
        commitTranscription()
    }

    /// The switch is the download button: there is nothing to decide between
    /// "I want this" and "fetch the model", so asking twice is a step for its
    /// own sake.
    ///
    /// The choice is written before the download starts, and that order is
    /// the whole of it. Starting the download first redraws the form — so
    /// the footer says what is happening from the first second — and the
    /// redraw puts the switch back where the config still has it, which is
    /// off; the write that followed then read the switch and saved the
    /// arrangement the click was trying to leave. Written first, the redraw
    /// reads a config that already says local, so the download's own redraw
    /// has nothing left to undo.
    ///
    /// It also means a download that fails or is abandoned leaves the choice
    /// on disk, which is what makes the footer go on offering it: the button
    /// asks whether the local model is wanted and missing, and a choice that
    /// was never written is not wanted.
    @objc private func localToggled() {
        commitTranscription()
        if localSwitch.state == .on { downloadLocalIfNeeded() }
    }

    private func localEnginePicked(_ id: String) {
        localEngineCards.select(id)
        commitTranscription()
        if localSwitch.state == .on { downloadLocalIfNeeded(id) }
    }

    @objc private func downloadLocalClicked(_ sender: NSButton) {
        let prefix = "transcription.download."
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix(prefix)
        else { return }
        let id = String(raw.dropFirst(prefix.count))
        guard Config.localEngines.contains(id) else { return }
        localEngineCards.select(id)
        localSwitch.state = .on
        commitTranscription()
        downloadLocalIfNeeded(id)
    }

    private func commitTranscription() {
        let selectedLocal = localEngineCards.selected
            ?? transcriptionChoice.localEngine
        let choice = TranscriptionChoice(
            cloud: cloudSwitch.state == .on,
            local: localSwitch.state == .on && Platform.supportsLocalModels,
            provider: provider,
            localEngine: selectedLocal)
        for update in choice.updates {
            write(update.path, update.value)
        }
        refresh()
    }

    /// Whichever window is showing the form — the setup wizard or the
    /// settings tab. The form does not own a window and must not assume one.
    private func focusKeyField() {
        view.window?.makeFirstResponder(cloudKey)
    }

    @objc private func liveTranscriptionToggled() {
        let enabled = liveTranscription.state == .on
        Config.update(path: ["live_transcription", "enabled"], value: enabled ? true : nil)
        if enabled {
            downloadLiveModel()
        } else {
            liveDownloadTask?.cancel()
            liveDownloadTask = nil
            liveDownloading = false
            refresh()
        }
    }

    private func downloadLiveModel() {
        guard !liveDownloading else { return }
        let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        if liveModelStore.isReady(language: prompt) {
            liveStatus.stringValue = localised("downloaded", "скачана")
            refresh()
            return
        }
        Analytics.track(.modelDownloadStarted, [.asset: .text("nemotron-live")])
        liveDownloading = true
        liveStatus.stringValue = localised("preparing download…", "готовлюсь скачивать…")
        refresh()
        liveDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await liveModelStore.download(language: prompt) { [weak self] fraction in
                    Task { @MainActor in
                        self?.liveStatus.stringValue = localised(
                            "downloading — \(Int(fraction * 100))% of about 600 MB",
                            "скачивание — \(Int(fraction * 100))% из примерно 600 МБ")
                    }
                }
                if liveModelStore.isReady(language: prompt) {
                    Analytics.track(.modelDownloadFinished, [.asset: .text("nemotron-live")])
                    liveStatus.stringValue = localised("downloaded", "скачана")
                } else {
                    Analytics.track(.modelDownloadFailed, [
                        .asset: .text("nemotron-live"),
                        .reason: .text(Analytics.Reason.noModel.rawValue),
                    ])
                    liveStatus.stringValue = localised(
                        "download incomplete — turn off and on to retry",
                        "скачалось не всё — выключите и включите, чтобы повторить")
                }
            } catch is CancellationError {
                liveStatus.stringValue = localised("download paused", "скачивание остановлено")
            } catch {
                Analytics.track(.modelDownloadFailed, [
                    .asset: .text("nemotron-live"),
                    .reason: .text(Analytics.reason(for: error).rawValue),
                ])
                liveStatus.stringValue =
                    localised("download failed: ", "не удалось скачать: ")
                        + error.localizedDescription
            }
            liveDownloading = false
            liveDownloadTask = nil
            refresh()
        }
    }

    @objc private func autoRecordToggled() {
        Config.update(
            path: ["auto_record", "enabled"], value: autoRecord.state == .on ? nil : false)
    }

    @objc private func analyticsToggled() {
        Config.update(path: ["analytics"], value: analytics.state == .on ? nil : false)
    }

    @objc private func summariesToggled() {
        Config.update(path: ["summary", "enabled"], value: summariesOn.state == .on ? nil : false)
        refresh()
    }

    @objc private func keyProviderChanged() {
        // Only here, not in every redraw: a redraw follows the very write
        // that says a key was saved, and used to wipe "key works" off the
        // screen the moment it appeared.
        summaryKeyStatus.stringValue = ""
        summaryKey.stringValue = ""
        let backend = selectedKeyBackend
        let compatible = keyProvider.selectedSegment == 2
        if backend == "openai-api" {
            Config.update(path: ["summary", "openai_compatible"], value: compatible)
        }
        if summaryCards.selected == "api-key" {
            Config.update(path: ["summary", "backend"], value: backend)
        }
        showKeyProvider()
    }

    /// Everything the Anthropic/OpenAI control changes about how its card
    /// *looks* — and nothing it writes.
    ///
    /// Split out because `refresh` needs the looking and must not do the
    /// writing. A redraw that writes rewrites the config file every time
    /// anything is drawn, and once something listens for writes in order to
    /// redraw — which is the whole point of `Config.didChange` — a redraw that
    /// writes is a redraw that never stops.
    private func showKeyProvider() {
        summaryKey.placeholderString = selectedKeyBackend == "anthropic-api"
            ? "sk-ant-…" : localised("API key", "API-ключ")
        summaryOpenAIOptions.isHidden = selectedKeyBackend != "openai-api"
        summaryOpenAIBaseURLRow?.isHidden = keyProvider.selectedSegment != 2
        summaryKeyLink.isHidden = keyProvider.selectedSegment == 2
        summaryKeyLink.identifier = NSUserInterfaceItemIdentifier(
            selectedKeyBackend == "anthropic-api"
                ? "https://console.anthropic.com/settings/keys"
                : "https://platform.openai.com/api-keys")
    }

    private var selectedKeyBackend: String {
        keyProvider.selectedSegment == 1 ? "anthropic-api" : "openai-api"
    }

    private func configureSummaryField(_ field: NSTextField, id: String) {
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.font = SetupLayout.detailFont
        field.delegate = self
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func summaryFieldRow(_ title: String, _ field: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = SetupLayout.detailFont
        label.textColor = .secondaryLabelColor
        // Wide enough for "URL сервера": at 62 the Russian label was cut to
        // "URL сервер" in the Ollama card, the width having been measured
        // against "Base URL" alone.
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        field.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    /// Register with Login Items, the way every other application does.
    private func startAtLogin() {
        if isRecording?() == true {
            report(launchRow, localised(
                "not while a recording is running — stop it and try again",
                "не сейчас: идёт запись — остановите её и попробуйте снова"))
            return
        }
        do {
            let state = try LoginItem.register()
            // Registered but held: macOS wants a person to say yes, and the
            // only place they can is System Settings.
            if state == .needsApproval { LoginItem.openSettings() }
        } catch {
            report(launchRow, localised("couldn't register at login: ", "не удалось включить: ")
                + error.localizedDescription)
        }
        refresh()
    }

    private func askMicrophone() async {
        let state = await SetupPermissions.requestMicrophone()
        if state == .denied { SetupPermissions.openSettings(.microphone) }
        refresh()
    }

    private func askCalendar() async {
        let state = await SetupPermissions.requestCalendar()
        calendarGrant = state
        if state == .denied { SetupPermissions.openSettings(.calendar) }
        refresh()
    }

    /// What the calendar prompt answered, for as long as this window is open.
    /// Kept because EventKit will not admit to a grant given in this process
    /// until the next launch, and a row that still says "optional" after the
    /// person has just said yes is the button looking broken all over again.
    private var calendarGrant: SetupPermissions.State?

    /// Play a tone and listen for it through a tap of our own.
    ///
    /// Never during a recording, which the comment on `isRecording` promised
    /// and only the login item kept: the test opens a second tap beside the
    /// one recording the meeting and plays 440 Hz out of the speakers, into
    /// the call — the far end hears it, and it lands in the recording too.
    /// The wizard's button reaches this as well as the row's, so the refusal
    /// is here rather than on either button.
    private func testSystemAudio() async {
        if isRecording?() == true {
            toneRefused = true
            refresh()
            return
        }
        audioRow.working(localised("playing a tone…", "играет тон…"))
        let result = await playTestTone()
        systemAudio = result
        if result == .heard { SetupState.rememberSystemAudioHeard() }
        switch result {
        case .heard:
            break
        case .silent, .refused:
            SetupPermissions.openSettings(.systemAudio)
        }
        refresh()
    }

    /// The test was asked for during a recording and refused. Kept rather
    /// than written once into the row, because the next redraw — any write
    /// to the config, from anywhere — would put the row back as if nothing
    /// had been asked, while the recording that is the reason goes on.
    private var toneRefused = false

    /// Seeded from the last tone that was heard, because macOS will not tell
    /// us and a working Mac should not be asked to prove itself every time.
    private lazy var systemAudio: SetupPermissions.SystemAudioResult? =
        SetupPermissions.rememberedSystemAudio(heardAt: SetupState.systemAudioHeardAt())

    private func downloadLocalIfNeeded(_ requestedEngine: String? = nil) {
        let engine = requestedEngine ?? transcriptionChoice.localEngine
        localDownloadErrors[engine] = nil
        parakeetStatus.stringValue = ""
        if engine == "whisper" {
            downloadWhisperIfNeeded()
        } else if engine == "gigaam" {
            downloadGigaAMIfNeeded()
        } else {
            downloadParakeetIfNeeded()
        }
    }

    private func downloadGigaAMIfNeeded() {
        guard gigaAMModelStore.bytesOnDisk == 0, gigaAMDownloadTask == nil else { return }
        let asset = "gigaam-v3-e2e-ctc-q8_0"
        Analytics.track(.modelDownloadStarted, [.asset: .text(asset)])
        parakeetBar.minValue = 0
        parakeetBar.maxValue = 1
        parakeetBar.doubleValue = 0
        parakeetBar.isHidden = false
        parakeetStatus.isHidden = false
        gigaAMDownloadTask = Task { [self, gigaAMModelStore] in
            do {
                _ = try await gigaAMModelStore.download { update in
                    Task { @MainActor [self] in
                        parakeetBar.isHidden = false
                        if let fraction = update.fraction {
                            parakeetBar.isIndeterminate = false
                            parakeetBar.doubleValue = fraction
                            parakeetStatus.stringValue = localised(
                                "downloading · \(Int(fraction * 100))% of about 260 MB",
                                "скачивание · \(Int(fraction * 100))% из примерно 260 МБ")
                            localEngineCards.card("gigaam")?.report(parakeetStatus.stringValue)
                        } else {
                            parakeetBar.isIndeterminate = true
                            parakeetBar.startAnimation(nil)
                            parakeetStatus.stringValue = localised(
                                "downloading · about 260 MB",
                                "скачивание · около 260 МБ")
                            localEngineCards.card("gigaam")?.report(parakeetStatus.stringValue)
                        }
                    }
                }
                Analytics.track(.modelDownloadFinished, [.asset: .text(asset)])
            } catch is CancellationError {
                // The chosen engine remains selected and can resume next time.
            } catch {
                Analytics.track(.modelDownloadFailed, [
                    .asset: .text(asset),
                    .reason: .text(Analytics.reason(for: error).rawValue),
                ])
                localDownloadErrors["gigaam"] =
                    localised("download failed: ", "не удалось скачать: ") + "\(error)"
            }
            parakeetBar.stopAnimation(nil)
            parakeetBar.isIndeterminate = false
            parakeetBar.isHidden = true
            gigaAMDownloadTask = nil
            refresh()
        }
        refresh()
    }

    private func downloadWhisperIfNeeded() {
        guard whisperModelStore.bytesOnDisk == 0, whisperDownloadTask == nil else { return }
        Analytics.track(.modelDownloadStarted, [.asset: .text("whisper-large-v3-turbo-q5_0")])
        parakeetBar.minValue = 0
        parakeetBar.maxValue = 1
        parakeetBar.doubleValue = 0
        parakeetBar.isHidden = false
        parakeetStatus.isHidden = false
        whisperDownloadTask = Task { [self, whisperModelStore] in
            do {
                _ = try await whisperModelStore.download { update in
                    Task { @MainActor [self] in
                        self.parakeetBar.isHidden = false
                        if let fraction = update.fraction {
                            self.parakeetBar.isIndeterminate = false
                            self.parakeetBar.doubleValue = fraction
                            self.parakeetStatus.stringValue = localised(
                                "downloading · \(Int(fraction * 100))% of about 550 MB",
                                "скачивание · \(Int(fraction * 100))% из примерно 550 МБ")
                            self.localEngineCards.card("whisper")?.report(
                                self.parakeetStatus.stringValue)
                        } else {
                            self.parakeetBar.isIndeterminate = true
                            self.parakeetBar.startAnimation(nil)
                            self.parakeetStatus.stringValue = localised(
                                "downloading · about 550 MB",
                                "скачивание · около 550 МБ")
                            self.localEngineCards.card("whisper")?.report(
                                self.parakeetStatus.stringValue)
                        }
                    }
                }
                Analytics.track(.modelDownloadFinished, [
                    .asset: .text("whisper-large-v3-turbo-q5_0"),
                ])
            } catch is CancellationError {
                // Closing setup pauses an optional download without turning
                // the chosen engine back into another one.
            } catch {
                Analytics.track(.modelDownloadFailed, [
                    .asset: .text("whisper-large-v3-turbo-q5_0"),
                    .reason: .text(Analytics.reason(for: error).rawValue),
                ])
                self.localDownloadErrors["whisper"] =
                    localised("download failed: ", "не удалось скачать: ") + "\(error)"
            }
            self.parakeetBar.stopAnimation(nil)
            self.parakeetBar.isIndeterminate = false
            self.parakeetBar.isHidden = true
            self.whisperDownloadTask = nil
            self.refresh()
        }
        refresh()
    }

    private func downloadParakeetIfNeeded() {
        guard !parakeetIsHere() else { return }
        guard parakeetDownload == nil else { return }
        let asset = Config.transcriptionModel() == "v2" ? "parakeet-v2" : "parakeet-v3"
        Analytics.track(.modelDownloadStarted, [.asset: .text(asset)])
        watchParakeetSize()
        let fetch = fetchParakeet
        parakeetDownload = Task { [weak self] in
            var failure: String?
            do {
                try await fetch()
                Analytics.track(.modelDownloadFinished, [.asset: .text(asset)])
            } catch {
                Analytics.track(.modelDownloadFailed, [
                    .asset: .text(asset),
                    .reason: .text(Analytics.reason(for: error).rawValue),
                ])
                failure = localised("download failed: ", "не удалось скачать: ") + "\(error)"
            }
            guard let self else { return }
            if let failure { localDownloadErrors["parakeet"] = failure }
            parakeetDownload = nil
            parakeetProgress?.invalidate()
            parakeetProgress = nil
            parakeetBar.isHidden = true
            refresh()
        }
        // So the footer button says what is happening from the first second,
        // rather than at the end of it.
        refresh()
    }

    /// FluidAudio hands back no progress, so the progress is the cache
    /// directory growing. Approximate, and better than a spinner that could
    /// mean anything.
    private func watchParakeetSize() {
        parakeetProgress?.invalidate()
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetEngine.configuredVersion())
        parakeetBar.isHidden = false
        parakeetStatus.isHidden = false
        parakeetBar.isIndeterminate = false
        parakeetBar.maxValue = Double(Self.parakeetMegabytes)
        parakeetBar.doubleValue = 0
        parakeetProgress = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let mb = Self.megabytes(of: cache)
                self?.parakeetBar.doubleValue = Double(mb)
                self?.parakeetStatus.stringValue = localised(
                    "\(mb) of about \(Self.parakeetMegabytes) MB",
                    "\(mb) из примерно \(Self.parakeetMegabytes) МБ")
                if let status = self?.parakeetStatus.stringValue {
                    self?.localEngineCards.card("parakeet")?.report(status)
                }
            }
        }
    }

    private static func megabytes(of dir: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total / 1_048_576
    }

    // MARK: - text fields

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === cloudKey { Task { await saveCloudKey() } }
        if field === summaryKey { Task { await saveSummaryKey() } }
        let summaryPaths: [(NSTextField, String)] = [
            (summaryOpenAIBaseURL, "openai_base_url"),
            (summaryOpenAIModel, "openai_model"),
            (summaryOllamaBaseURL, "ollama_base_url"),
            (summaryOllamaModel, "ollama_model"),
        ]
        if let key = summaryPaths.first(where: { $0.0 === field })?.1 {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Config.update(path: ["summary", key], value: value.isEmpty ? nil : value)
            refresh()
        }
    }

    /// Return in a key field submits the key and stops there.
    ///
    /// Left alone, the newline travels on to the window's default button —
    /// Done — so the window closes on the very keystroke that submits the key.
    /// The check against the API then finishes into a window nobody can see,
    /// and the one answer worth waiting for, whether the key was accepted,
    /// is delivered to nothing at all. Someone who pasted a key and pressed
    /// Return has no way to learn what happened except to open Setup again.
    ///
    /// Ending editing here is the same path a click elsewhere takes — it fires
    /// `controlTextDidEndEditing`, which saves — and returning true keeps the
    /// keystroke from travelling any further. Only these two fields swallow
    /// Return: everywhere else in the window it should still mean Done.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)),
              control === cloudKey || control === summaryKey
                || control === summaryOpenAIBaseURL || control === summaryOpenAIModel
                || control === summaryOllamaBaseURL || control === summaryOllamaModel
        else { return false }
        control.window?.makeFirstResponder(nil)
        return true
    }

    @objc private func languageChanged() {
        Config.update(path: ["transcription", "language"], value: selectedLanguage)
        refresh()
    }

    /// What the choice above actually promises, in the one place somebody is
    /// looking at it. Picking English says nothing worth saying — it is the
    /// language the second slot would have added anyway.
    private static func note(forLanguage code: String?) -> String {
        guard let code else {
            return localised(
                "Both engines work it out from the audio. Naming a language "
                    + "keeps a short or noisy meeting from being taken for another one.",
                "Оба движка определяют язык по звуку. Названный язык не даст принять "
                    + "короткую или шумную встречу за другую.")
        }
        guard code != "en" else { return "" }
        return localised(
            "English meetings are recognised too — nothing to switch.",
            "Встречи на английском тоже распознаются — переключать ничего не надо.")
    }

    /// What a key field says while the provider is being asked.
    ///
    /// Named rather than written out at each of the three places that need
    /// it, because one of them needs it by *comparison* — the redraw clears a
    /// stale "checking…" and leaves anything else alone. Two literals agree
    /// in one language and stop agreeing in the other, which would leave a
    /// Russian window saying it was still checking a key it had finished
    /// with.
    private static var checkingKey: String { localised("checking…", "проверяю…") }

    /// Check first, write second.
    ///
    /// The other order costs someone their working key: two characters typed
    /// into the field by accident used to replace a good key on disk, and the
    /// only sign was every later meeting failing to transcribe with HTTP 401.
    /// A key that isn't accepted never reaches the file.
    func saveCloudKey() async {
        let target = pendingProvider ?? provider
        let key = cloudKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let slot = Credentials.transcriptionSlot(for: target, in: Config.raw())
        guard slot.isAmanus else {
            cloudKeyStatus.stringValue = Credentials.notOursToWrite(slot)
            return
        }
        cloudKeyStatus.stringValue = Self.checkingKey

        let service: Credentials.Check.Service
        switch target {
        // Transcription only ever talks to OpenAI itself, whatever endpoint
        // the summaries are pointed at.
        case "openai": service = .openAI(baseURL: "https://api.openai.com/v1")
        case "elevenlabs": service = .elevenLabs
        default: service = .assemblyAI
        }
        let verdict = await checkKey(Credentials.Check(service: service, key: key))
        guard verdict == .works else {
            cloudKeyStatus.stringValue = verdict.sentence(
                keepingSaved: Credentials.hasTranscriptionKey(for: target))
            return
        }
        do {
            try Credentials.writeSecret(key, to: slot.path)
        } catch {
            cloudKeyStatus.stringValue =
                localised("couldn't save the key: ", "не удалось сохранить ключ: ") + "\(error)"
            return
        }
        cloudKey.stringValue = ""
        cloudKeyStatus.stringValue = verdict.sentence(keepingSaved: true)
        // A key that works is the answer to the question the switch asked, so
        // it turns the cloud on rather than making the person click twice.
        provider = target
        pendingProvider = nil
        cloudSwitch.state = .on
        commitTranscription()
    }

    /// The same order as the cloud key, into the slot the summary actually
    /// reads — which for an OpenAI-compatible endpoint is not OpenAI's.
    func saveSummaryKey() async {
        let key = summaryKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let backend = selectedKeyBackend
        let config = Config.raw()
        let slot = Credentials.summarySlot(for: backend, in: config)
        guard slot.isAmanus else {
            summaryKeyStatus.stringValue = Credentials.notOursToWrite(slot)
            return
        }
        summaryKeyStatus.stringValue = Self.checkingKey
        let service: Credentials.Check.Service = backend == "anthropic-api"
            ? .anthropic
            : .openAI(baseURL: Config.summary(in: config).openAIBaseURL)
        let verdict = await checkKey(Credentials.Check(service: service, key: key))
        guard verdict == .works else {
            summaryKeyStatus.stringValue = verdict.sentence(
                keepingSaved: Config.secret(at: slot.path) != nil)
            return
        }
        do {
            try Credentials.writeSecret(key, to: slot.path)
        } catch {
            summaryKeyStatus.stringValue =
                localised("couldn't save the key: ", "не удалось сохранить ключ: ") + "\(error)"
            return
        }
        summaryKey.stringValue = ""
        summaryKeyStatus.stringValue = verdict.sentence(keepingSaved: true)
        Config.update(path: ["summary", "backend"], value: backend)
        refresh()
    }

    // MARK: - reading the machine

    func detectTools() async {
        // The form is reopened for exactly one reason: something about the
        // machine changed. Usually it is the **Install it** link having been
        // followed — so the cached "not here" from the last look is the one
        // answer guaranteed to be wrong now.
        Tooling.forget()

        // Off the main actor: `Tooling` may start a login shell and run the
        // binaries it finds, which is seconds, not milliseconds.
        let claude = await Task.detached { Tooling.probe("claude") }.value
        let codex = await Task.detached { Tooling.probe("codex") }.value
        let ollama = await Task.detached { Tooling.probe("ollama") }.value
        let models = await Tooling.ollamaModels()

        for (id, tool) in [("claude-cli", claude), ("codex-cli", codex)] {
            summaryCards.card(id)?.report(Self.describe(tool), good: tool?.version != nil)
            summaryCards.card(id)?.showLink(tool == nil)
        }

        let ollamaCard = summaryCards.card("ollama")
        let ollamaIsLocal = OllamaClient.isLocal(baseURL: Config.summary().ollamaBaseURL)
        if let models {
            let names = models.prefix(2).map(\.name).joined(separator: ", ")
            let selected = SetupSelection.ollamaModel(
                named: Config.summary().ollamaModel, in: models)
            ollamaCard?.report(
                models.isEmpty
                    ? localised("running, no models", "работает, моделей нет")
                    : selected == nil
                        ? localised(
                            "selected model missing · ",
                            "нет выбранной модели · ") + names
                        : localised("running · ", "работает · ")
                        + names
                        + (ollamaIsLocal && selected?.isRemote == false
                            ? "" : localised(" · remote", " · удалённо")),
                good: selected != nil)
        } else {
            ollamaCard?.report(ollama == nil
                ? localised("not here", "не установлена")
                : localised("installed, not running", "установлена, но не запущена"))
        }
        ollamaCard?.showLink(ollama == nil && ollamaIsLocal)

        summaryToolRuns = [
            "claude-cli": claude?.runs == true,
            "codex-cli": codex?.runs == true,
            "ollama": models.map {
                SetupSelection.ollamaModel(
                    named: Config.summary().ollamaModel, in: $0) != nil
            } ?? false,
        ]
        refresh()
    }

    private static func describe(_ tool: Tooling.Found?) -> String {
        guard let tool else { return localised("not here", "не установлен") }
        guard let version = tool.version else {
            return localised(
                "found but it doesn't run from here", "нашёлся, но отсюда не запускается")
        }
        return localised("answers · ", "отвечает · ") + version
    }

    /// Whether the local model is on this Mac. A Mac that cannot run it at
    /// all is not missing it, so the question is answered yes there and the
    /// window stops asking.
    private var localModelIsDownloaded: Bool {
        guard Platform.supportsLocalModels else { return true }
        switch transcriptionChoice.localEngine {
        case "whisper": return whisperModelStore.bytesOnDisk > 0
        case "gigaam": return gigaAMModelStore.bytesOnDisk > 0
        default: return parakeetIsHere()
        }
    }

    /// The two switches as the config file has them.
    private var transcriptionChoice: TranscriptionChoice {
        storedTranscription()
    }

    /// Asked for, and not here. **On this Mac** is the whole question: both
    /// switches on is still asking for the local model, because that is the
    /// setting that transcribes when the network doesn't.
    private var localModelIsWantedAndMissing: Bool {
        transcriptionChoice.needsLocalModel(downloaded: localModelIsDownloaded)
    }

    /// Summaries are on and the thing chosen to write them is not on this
    /// Mac. The card says "not here" in orange; this is what puts it in the
    /// one line somebody reads before pressing Done.
    private var chosenSummaryIsMissing: Bool {
        let summary = Config.summary()
        guard summary.enabled else { return false }
        switch SetupSelection.summaryChoice(backend: summary.backend) {
        case let looked where summaryToolRuns[looked] != nil:
            return summaryToolRuns[looked] == false
        case "api-key":
            return summary.backend == "openai-api"
                ? Credentials.summaryOpenAIKey() == nil
                : Config.anthropicKey() == nil
        default:
            return false
        }
    }

    // MARK: - refresh

    /// Redraw everything from the machine and the config file. Cheap: no
    /// subprocesses, no network — those write into fields this only reads.
    /// Public because the settings window's other tab writes the same keys,
    /// and a change made there has to reach these controls rather than wait
    /// for the window to be reopened.
    func refresh() {
        switch LoginItem.status() {
        case .enabled:
            launchRow.update(.granted, note: localised("on", "включено"))
        case .needsApproval:
            launchRow.update(
                .denied,
                detail: localised(
                    "macOS wants this allowed in Login Items.",
                    "macOS хочет, чтобы это разрешили в объектах входа."),
                action: localised("Open Settings", "Открыть настройки"))
        case .notRegistered:
            launchRow.update(.notAsked, detail: localised(
                "So a meeting is never missed.", "Чтобы ни одна встреча не пропала."))
        case .unavailable:
            launchRow.update(
                .notAsked,
                detail: localised(
                    "Only Amanu.app can register itself; this is a bare build.",
                    "Зарегистрировать себя может только Amanu.app, а это голая сборка."))
        }
        micRow.update(SetupPermissions.microphone())
        calendarRow.update(calendarGrant ?? SetupPermissions.calendar())

        if toneRefused, isRecording?() != true { toneRefused = false }
        switch systemAudio {
        case _ where toneRefused:
            audioRow.update(.denied, detail: localised(
                "not while a recording is running — the test tone would play into the call",
                "не во время записи — тестовый тон прозвучит в звонке"))
        case .heard:
            audioRow.update(
                .granted,
                note: SetupState.systemAudioHeardAt().map {
                    localised("heard the tone · ", "тон услышан · ")
                        + Self.day.string(from: $0)
                } ?? localised("heard the tone", "тон услышан"),
                action: localised("Test again", "Проверить ещё раз"))
        case .silent:
            audioRow.update(.denied, detail: localised(
                "Recorded silence. Check the grant, or turn the volume up, and test again.",
                "Записалась тишина. Проверьте разрешение или прибавьте громкость и "
                    + "попробуйте снова."))
        case .refused(let why): audioRow.update(.denied, detail: why)
        case nil: audioRow.update(.notAsked)
        }

        let config = Config.raw()
        refreshTranscription()
        // A code the menu doesn't offer — hand-edited, or a leftover "ru-RU"
        // — selects Detect automatically, which is what the engines will
        // actually do with it. Shown as it will behave rather than as it is
        // written, and left in the file for its owner to change.
        let stored = Config.transcriptionLanguage()
        let item = language.menu?.items.first { $0.representedObject as? String == stored }
        language.select(item ?? language.menu?.items.first)
        languageNote.stringValue = Self.note(forLanguage: item?.representedObject as? String)
        languageNote.isHidden = languageNote.stringValue.isEmpty
        keepAudio.state = Config.keepAudio() ? .on : .off

        liveTranscription.state = Config.liveTranscriptionEnabled() ? .on : .off
        refreshDiarization()
        let livePrompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        if liveModelStore.isReady(language: livePrompt) {
            liveStatus.stringValue = Self.downloaded(modelStorage.liveModel())
            liveStatus.textColor = .systemGreen
        } else if !liveDownloading, Config.liveTranscriptionEnabled(), liveStatus.stringValue.isEmpty {
            liveStatus.stringValue = localised(
                "about 600 MB — downloads when switched on",
                "около 600 МБ — скачается при включении")
        } else if !Config.liveTranscriptionEnabled() {
            liveStatus.stringValue = localised("optional", "по желанию")
        }

        recordingsPath.stringValue = Home.current.abbreviating(
            Config.resolveRoot(cliOverride: nil).path)

        let summary = Config.summary()
        summariesOn.state = summary.enabled ? .on : .off
        let backendIsKey = summary.backend == "anthropic-api" || summary.backend == "openai-api"
        summaryCards.select(SetupSelection.summaryChoice(backend: summary.backend))
        if backendIsKey {
            keyProvider.selectedSegment = summary.backend == "anthropic-api" ? 1
                : (summary.openAICompatible ? 2 : 0)
        }
        summaryOpenAIBaseURL.stringValue = summary.openAIBaseURL
        summaryOpenAIModel.stringValue = summary.openAIModel
        summaryOllamaBaseURL.stringValue = summary.ollamaBaseURL
        summaryOllamaModel.stringValue = summary.ollamaModel
        showKeyProvider()
        for card in summaryCards.cards { card.isEnabled = summary.enabled }

        menuBarIcon.state = Config.menuBarIcon() ? .on : .off
        dockIcon.state = Config.dockIcon() ? .on : .off
        noIconsNote.stringValue = Self.noIconsNote(
            menuBar: Config.menuBarIcon(), dock: Config.dockIcon())
        noIconsNote.isHidden = noIconsNote.stringValue.isEmpty

        let autoRecordOn = Config.flag(.autoRecordEnabled, in: config)
        autoRecord.state = autoRecordOn ? .on : .off
        analytics.state = AnalyticsIdentity.isEnabled() ? .on : .off

        let problems = showsConfigProblems ? Config.problems() : []
        configProblems.stringValue = problems.map(\.explanation).joined(separator: "\n")
        configProblems.isHidden = problems.isEmpty

        highlightNextGrant()
        onStateChange?()
    }

    /// The transcription section, redrawn from the config and from what is
    /// actually on disk: which keys exist, whether the local model is there.
    private func refreshTranscription() {
        let choice = transcriptionChoice
        provider = choice.provider
        pendingProvider = TranscriptionChoice.stillPending(pendingProvider) {
            Credentials.hasTranscriptionKey(for: $0)
        }

        cloudSwitch.state = choice.cloud ? .on : .off
        // The card under the key field is the one being answered, so a
        // provider waiting for a key is the one shown chosen.
        providerCards.select(pendingProvider ?? provider)

        for card in providerCards.cards {
            let known = Credentials.hasTranscriptionKey(for: card.id)
            card.report(
                known
                    ? localised("key works", "ключ работает")
                    : localised("no key yet", "ключа ещё нет"),
                good: known)
            card.showLink(!known)
        }
        cloudKey.placeholderString = (pendingProvider ?? provider) == "openai"
            ? "sk-…" : localised("paste key", "вставьте ключ")
        // Written on every pass rather than only into an empty label: a line
        // left over from the last question describes the wrong one.
        if let prompt = TranscriptionChoice.keyPrompt(
            pending: pendingProvider, inForce: provider, cloudOn: choice.cloud) {
            cloudKeyStatus.stringValue = prompt
        } else if cloudKeyStatus.stringValue == Self.checkingKey {
            cloudKeyStatus.stringValue = ""
        }
        // The cards below carry the price and the key state, so the row speaks
        // only when a missing key is what holds the switch down.
        cloudStatus.stringValue = TranscriptionChoice.rowNeedsKey(
            pending: pendingProvider, cloudOn: choice.cloud)
            ? localised("needs a key", "нужен ключ") : ""
        keyLine.isHidden = pendingProvider == nil && Credentials.hasTranscriptionKey(for: provider)

        localSwitch.isEnabled = Platform.supportsLocalModels
        localSwitch.state = choice.local ? .on : .off
        localEngineCards.select(choice.localEngine)
        for card in localEngineCards.cards {
            card.isEnabled = Platform.supportsLocalModels
            let button = localDownloadButtons[card.id]
            guard Platform.supportsLocalModels else {
                card.report(localised("needs Apple Silicon", "нужен Apple Silicon"))
                button?.isHidden = true
                continue
            }

            let model = localModel(card.id)
            if isLocalModelDownloaded(card.id, model: model) {
                card.report(
                    model.bytes > 0
                        ? Self.downloaded(model)
                        : localised("downloaded", "скачана"),
                    good: true)
                button?.isHidden = true
            } else if localModelIsDownloading(card.id) {
                card.report(localised(
                    "downloading · about \(localModelMegabytes(card.id)) MB",
                    "скачивание · около \(localModelMegabytes(card.id)) МБ"))
                button?.isHidden = true
            } else if let error = localDownloadErrors[card.id] {
                card.report(error)
                button?.isHidden = false
            } else {
                card.report("")
                button?.isHidden = false
            }
        }

        let downloading = localEngineCards.cards.contains {
            localModelIsDownloading($0.id)
        }
        if !downloading {
            parakeetBar.stopAnimation(nil)
            parakeetBar.isHidden = true
            parakeetStatus.isHidden = true
            parakeetStatus.stringValue = ""
        }
    }

    private func localModel(_ id: String) -> ModelStorage.Model {
        switch id {
        case "whisper": return modelStorage.whisperModel()
        case "gigaam": return modelStorage.gigaAMModel()
        default: return modelStorage.parakeet(version: ParakeetEngine.configuredVersion())
        }
    }

    private func isLocalModelDownloaded(_ id: String, model: ModelStorage.Model) -> Bool {
        id == "parakeet" ? parakeetIsHere() : model.isDownloaded
    }

    private func localModelIsDownloading(_ id: String) -> Bool {
        switch id {
        case "whisper": return whisperDownloadTask != nil
        case "gigaam": return gigaAMDownloadTask != nil
        default: return parakeetDownload != nil
        }
    }

    private func localModelMegabytes(_ id: String) -> Int {
        switch id {
        case "whisper": 550
        case "gigaam": 260
        default: Self.parakeetMegabytes
        }
    }

    /// A model that is here, and what it is costing to keep. The size is the
    /// half of this line a person can act on: the row above it says what the
    /// download would weigh, and only the Advanced tab can give the space
    /// back, so the number has to appear where somebody would go looking for
    /// it rather than only where it can be deleted.
    private static func downloaded(_ model: ModelStorage.Model) -> String {
        localised("downloaded · ", "скачана · ") + ModelStorage.describe(bytes: model.bytes)
    }

    /// Tint the row the primary button is about to act on — and only that
    /// one. The order below is the same one `nextAction` walks, because the
    /// highlight is meant to point at the button, not compete with it.
    private func highlightNextGrant() {
        let rows = [launchRow, micRow, audioRow, calendarRow]
        let pending: AccessRow?
        if SetupPermissions.needsStartAtLogin {
            pending = launchRow
        } else if SetupPermissions.microphone() != .granted {
            pending = micRow
        } else if SetupPermissions.needsSystemAudioTest(systemAudio) || systemAudio == .silent {
            pending = audioRow
        } else {
            pending = nil
        }
        for row in rows { row.setAttention(row === pending) }
    }

    /// The machine as it stands, for the three answers the wizard around the
    /// form needs — see `SetupProgress`. Read on every ask: the permission
    /// reads cost a round trip each, and `ThisTurn` is what keeps a redraw
    /// from paying for them more than once.
    var progress: SetupProgress {
        let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        let live = Config.liveTranscriptionEnabled()
        return SetupProgress(SetupProgress.Machine(
            loginItem: LoginItem.status(),
            microphone: SetupPermissions.microphone(),
            systemAudio: systemAudio,
            missingLocalModel: localModelIsWantedAndMissing
                ? transcriptionChoice.localEngine : nil,
            localModelDownloading: parakeetDownload != nil || whisperDownloadTask != nil
                || gigaAMDownloadTask != nil,
            liveModelWanted: live,
            liveModelReady: live && liveModelStore.isReady(language: prompt),
            liveModelDownloading: liveDownloading,
            summaryToolMissing: chosenSummaryIsMissing))
    }

    /// What the setup window's primary button will do, or nil when there is
    /// nothing left to offer.
    var nextAction: (() -> Void)? {
        switch progress.next {
        case .startAtLogin: return { [weak self] in self?.startAtLogin() }
        case .askMicrophone: return { [weak self] in Task { await self?.askMicrophone() } }
        case .testSystemAudio: return { [weak self] in Task { await self?.testSystemAudio() } }
        case .downloadLocalModel: return { [weak self] in self?.downloadLocalIfNeeded() }
        case .downloadLiveModel: return { [weak self] in self?.downloadLiveModel() }
        case nil: return nil
        }
    }

    typealias Missing = SetupProgress.Missing

    /// What the machine still owes, in the order it has to be dealt with.
    var outstanding: [Missing] { progress.outstanding }

    /// The same list in a sentence, for the footer of either window.
    var outstandingSentence: String { progress.sentence }

    nonisolated static func sentence(for outstanding: [Missing]) -> String {
        SetupProgress.sentence(for: outstanding)
    }

    /// Whether a model is coming down right now — the work a host must not
    /// offer to start a second time.
    var isDownloading: Bool { progress.isDownloading }

    /// What the setup window's primary button says, given where things stand.
    var nextActionTitle: String { progress.nextTitle }

    private func report(_ row: AccessRow, _ message: String) {
        row.update(.denied, detail: message)
    }
}
