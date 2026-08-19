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

    /// The form itself, for a host to put in a scroll view.
    let view = FlippedStackView()


    private let launchRow = AccessRow(
        title: "Start at login",
        detail: "So a meeting is never missed because nobody opened amanu.",
        action: "Install",
        grantedNote: "installed")
    private let micRow = AccessRow(
        title: "Microphone",
        detail: "Your side of the call.",
        action: "Allow",
        grantedNote: "allowed")
    private let audioRow = AccessRow(
        title: "System audio",
        detail: "",
        action: "Allow and test",
        grantedNote: "heard the tone")
    private let calendarRow = AccessRow(
        title: "Calendar",
        detail: "Names the folder and the speakers from the invitees.",
        action: "Allow",
        grantedNote: "allowed",
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

    private let language = NSPopUpButton()
    private let languageNote = NSTextField(labelWithString: "")
    private let keepAudio = NSSwitch()
    private let liveTranscription = NSSwitch()
    private let liveStatus = NSTextField(labelWithString: "")
    private let liveModelStore = LiveTranscriptionModelStore()
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
    private var parakeetProgress: Timer?

    private let summariesOn = NSSwitch()
    private let summaryCards = ChoiceGroup()
    private let keyProvider = NSSegmentedControl(
        labels: ["Anthropic", "OpenAI"], trackingMode: .selectOne, target: nil, action: nil)
    private let summaryKey = NSSecureTextField()
    private let summaryKeyStatus = NSTextField(labelWithString: "")
    private lazy var summaryKeyLink = link(
        "Get a key", "https://console.anthropic.com/settings/keys")

    private let recordingsPath = NSTextField(labelWithString: "")
    private let autoRecord = NSSwitch()

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

        form.addArrangedSubview(SetupLayout.section(
            "Access",
            content: SetupLayout.box([launchRow, micRow, audioRow, calendarRow])))

        var transcription: [NSView] = [transcriptionRows(), languageRow()]
        // The live transcript is a local streaming model, so on an Intel Mac
        // there is nothing behind the switch. Left out rather than shown
        // switched off: an offer that can never be accepted.
        if Platform.supportsLocalModels {
            transcription.append(SetupLayout.box([liveTranscriptionRow()]))
        }
        form.addArrangedSubview(SetupLayout.section(
            "Transcription", content: SetupLayout.group(transcription)))

        form.addArrangedSubview(SetupLayout.section(
            "Files",
            content: SetupLayout.box([folderRow(), keepAudioRow()])))

        form.addArrangedSubview(SetupLayout.section(
            "Summaries",
            leading: summariesOn,
            content: summaryChoices()))

        // No heading of its own: one switch is not a section, and it belongs
        // at the end because it is the thing that makes all of the above run
        // without anyone opening this form again.
        form.addArrangedSubview(SetupLayout.box([autoRecordRow()]))

        for view in form.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: form.widthAnchor, constant: -2 * SetupLayout.gutter).isActive = true
        }

        wireActions()
        refresh()
    }

    /// Re-read the machine and the config file. A host calls this when the
    /// form comes back on screen: the menu and the status window both write
    /// `auto_record.enabled`, and a form showing yesterday's answer is worse
    /// than no form at all.
    func reload() {
        refresh()
        // Detection runs off the main thread: finding `claude` can mean
        // starting the login shell, and a form that freezes while it asks
        // would be a worse first impression than one that fills in.
        Task { await detectTools() }
    }

    /// Put down what outlives a keystroke. The setup window calls it on the
    /// way out: a timer polling a download directory has no reason to keep
    /// running behind a closed window.
    func stop() {
        parakeetProgress?.invalidate()
        parakeetProgress = nil
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
            title: SetupLayout.title("In the cloud"),
            detail: SetupLayout.detail(
                "Audio is uploaded to the provider's servers. Better on Russian, "
                    + "and tells apart multiple speakers.",
                lines: 2, width: 440),
            trailing: [cloudStatus])

        localSwitch.target = self
        localSwitch.action = #selector(localToggled)
        parakeetStatus.font = SetupLayout.statusFont
        parakeetStatus.textColor = .secondaryLabelColor
        parakeetStatus.lineBreakMode = .byTruncatingTail
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
            title: SetupLayout.title("On this Mac"),
            detail: SetupLayout.detail(
                "Nvidia parakeet, \(Self.parakeetMegabytes) MB download and disk usage. Nothing leaves "
                    + "the machine, only me / them in the transcript.",
                lines: 2, width: 440),
            trailing: [parakeetBar, parakeetStatus])

        // One row, not two, on an Intel Mac: there is no local model to offer,
        // and the row explains itself rather than vanishing.
        return SetupLayout.box([cloudRow, providerRow(), localRow])
    }

    /// The provider cards and the one key field they share, indented under
    /// the switch they belong to.
    private func providerRow() -> NSView {
        let assembly = ChoiceCard(
            id: "assemblyai",
            title: "AssemblyAI",
            detail: "$0.23 an hour. No limit on meeting length.",
            accessories: [link("Get a key", "https://www.assemblyai.com/dashboard/signup")])
        let openai = ChoiceCard(
            id: "openai",
            title: "OpenAI",
            detail: "$0.36 an hour. Same key as summaries.",
            accessories: [link("Get a key", "https://platform.openai.com/api-keys")])
        providerCards.adopt([assembly, openai])
        providerCards.onChange = { [weak self] id in self?.providerPicked(id) }

        cloudKey.placeholderString = "paste key"
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
        let label = NSTextField(labelWithString: "Meetings are mostly in")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor

        language.target = self
        language.action = #selector(languageChanged)
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
        let detect = NSMenuItem(title: "Detect automatically", action: nil, keyEquivalent: "")
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
            title: SetupLayout.title("I want a live transcript during meetings"),
            detail: SetupLayout.detail(
                "A 600 MB NVIDIA model downloads once. Nothing leaves this Mac, "
                    + "and the final transcript is still parakeet's.",
                lines: 2, width: 520),
            trailing: [liveStatus])
    }

    /// Where the recordings live, and the one thing worth saying about the
    /// default: it is outside Documents, Desktop and Downloads, so macOS never
    /// has to ask a background recorder for permission to write there.
    private func folderRow() -> NSView {
        recordingsPath.font = SetupLayout.monoFont
        recordingsPath.lineBreakMode = .byTruncatingMiddle

        return SetupLayout.row(
            symbol: "folder",
            title: recordingsPath,
            detail: SetupLayout.detail(
                "Outside Documents and Desktop, so macOS never has to ask.", lines: 1),
            trailing: [SetupLayout.actionButton(
                "Choose…", target: self, action: #selector(chooseFolder))])
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.resolveRoot(cliOverride: nil)
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Store it the way a person would write it: a path under the home
        // directory stays readable, and stays right if the account is renamed.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = chosen.path.hasPrefix(home)
            ? "~" + chosen.path.dropFirst(home.count)
            : chosen.path
        Config.update(path: ["recordings_dir"], value: String(path))
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
            title: SetupLayout.title("Keep the audio after transcribing"),
            trailing: [keepAudio])
    }

    private func summaryChoices() -> NSView {
        let claude = ChoiceCard(
            id: "claude-cli",
            title: "Claude Code",
            detail: "On the subscription you're already signed into. No key.",
            accessories: [link("Install it", "https://claude.com/product/claude-code")])
        let codex = ChoiceCard(
            id: "codex-cli",
            title: "Codex",
            detail: "Same deal, on your OpenAI subscription.",
            accessories: [link("Install it", "https://developers.openai.com/codex/cli/")])

        // Without this the switch still slides when you push it — NSSwitch
        // animates itself — while nothing at all happens: the choice is never
        // written, the cards below stay live, and every meeting is summarised
        // by a program the person just told to stop. It went unwired from the
        // day the section was built, because the only check for it was a
        // manual one nobody had run.
        summariesOn.target = self
        summariesOn.action = #selector(summariesToggled)

        keyProvider.selectedSegment = 0
        keyProvider.target = self
        keyProvider.action = #selector(keyProviderChanged)
        summaryKey.placeholderString = "sk-ant-…"
        summaryKey.font = SetupLayout.detailFont
        summaryKey.delegate = self
        summaryKeyStatus.font = SetupLayout.statusFont
        summaryKeyStatus.textColor = .secondaryLabelColor
        summaryKeyStatus.lineBreakMode = .byWordWrapping
        summaryKeyStatus.maximumNumberOfLines = 2
        let key = ChoiceCard(
            id: "api-key",
            title: "My own key",
            detail: "Billed per meeting, needs no CLI.",
            accessories: [keyProvider, summaryKey, summaryKeyStatus, summaryKeyLink])

        // Ollama is a fallback, not a fourth peer: a whole card beside the
        // three real choices reads as a recommendation, and its summaries are
        // the weakest of the four. One slim row keeps it choosable and says so.
        let ollama = ChoiceCard(
            id: "ollama",
            title: "Ollama",
            detail: "No account, no network. Weaker summaries.",
            accessories: [link("Install Ollama", "https://ollama.com/download/mac")],
            compact: true)

        summaryCards.adopt([claude, codex, key, ollama])
        summaryCards.onChange = { [weak self] id in
            guard let self else { return }
            Config.update(path: ["summary", "backend"], value: SetupSelection.summaryBackend(
                choice: id, keyBackend: self.selectedKeyBackend))
            self.refresh()
        }
        return SetupLayout.group(
            [SetupLayout.cards([claude, codex, key]), ollama],
            spacing: SetupLayout.cardGap)
    }

    private func autoRecordRow() -> NSView {
        autoRecord.target = self
        autoRecord.action = #selector(autoRecordToggled)
        return SetupLayout.row(
            leading: autoRecord,
            title: SetupLayout.title("Start recording automatically when a call app takes the mic"),
            detail: SetupLayout.detail(
                "And stop when it lets go. Recordings shorter than a minute are thrown away.",
                lines: 2, width: 520))
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    /// "18 Aug" — enough to tell this week from last spring, and short enough
    /// to sit beside a row title.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

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

    @objc private func keepAudioChanged() {
        Config.update(path: ["keep_audio"], value: keepAudio.state == .on ? true : nil)
    }

    /// The cloud switch. Turning it on for a service with no key does not
    /// turn it on: it opens the key field instead and leaves the switch where
    /// it was, because a switch that says "on" while every transcript fails
    /// with HTTP 401 is a lie the person only finds out about after a meeting.
    @objc private func cloudToggled() {
        if cloudSwitch.state == .on, !hasKey(for: provider) {
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
        guard hasKey(for: id) else {
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
    @objc private func localToggled() {
        if localSwitch.state == .on { downloadParakeetIfNeeded() }
        commitTranscription()
    }

    private func commitTranscription() {
        let choice = TranscriptionChoice(
            cloud: cloudSwitch.state == .on,
            local: localSwitch.state == .on && Platform.supportsLocalModels,
            provider: provider)
        for update in choice.updates {
            Config.update(path: update.path, value: update.value)
        }
        refresh()
    }

    private func hasKey(for provider: String) -> Bool {
        provider == "openai" ? Config.openAIKey() != nil : Config.assemblyAIKey() != nil
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
            liveStatus.stringValue = "downloaded"
            refresh()
            return
        }
        liveDownloading = true
        liveStatus.stringValue = "preparing download…"
        refresh()
        liveDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await liveModelStore.download(language: prompt) { [weak self] fraction in
                    Task { @MainActor in
                        self?.liveStatus.stringValue = "downloading — \(Int(fraction * 100))% of about 600 MB"
                    }
                }
                liveStatus.stringValue = liveModelStore.isReady(language: prompt)
                    ? "downloaded" : "download incomplete — turn off and on to retry"
            } catch is CancellationError {
                liveStatus.stringValue = "download paused"
            } catch {
                liveStatus.stringValue = "download failed: \(error.localizedDescription)"
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

    @objc private func summariesToggled() {
        Config.update(path: ["summary", "enabled"], value: summariesOn.state == .on ? nil : false)
        refresh()
    }

    @objc private func keyProviderChanged() {
        summaryKey.placeholderString = selectedKeyBackend == "anthropic-api" ? "sk-ant-…" : "sk-…"
        summaryKeyStatus.stringValue = ""
        summaryKeyLink.identifier = NSUserInterfaceItemIdentifier(
            selectedKeyBackend == "anthropic-api"
                ? "https://console.anthropic.com/settings/keys"
                : "https://platform.openai.com/api-keys")
        if summaryCards.selected == "api-key" {
            Config.update(path: ["summary", "backend"], value: selectedKeyBackend)
        }
    }

    private var selectedKeyBackend: String {
        keyProvider.selectedSegment == 1 ? "openai-api" : "anthropic-api"
    }

    /// Register with Login Items, the way every other application does.
    private func startAtLogin() {
        if isRecording?() == true {
            report(launchRow, "not while a recording is running — stop it and try again")
            return
        }
        do {
            let state = try LoginItem.register()
            // Registered but held: macOS wants a person to say yes, and the
            // only place they can is System Settings.
            if state == .needsApproval { LoginItem.openSettings() }
        } catch {
            report(launchRow, "couldn't register at login: \(error.localizedDescription)")
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

    private func testSystemAudio() async {
        audioRow.working("playing a tone…")
        let result = await SetupPermissions.testSystemAudio()
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

    /// Seeded from the last tone that was heard, because macOS will not tell
    /// us and a working Mac should not be asked to prove itself every time.
    private lazy var systemAudio: SetupPermissions.SystemAudioResult? =
        SetupPermissions.rememberedSystemAudio(heardAt: SetupState.systemAudioHeardAt())

    private func downloadParakeetIfNeeded() {
        let version = ParakeetEngine.configuredVersion()
        let cache = AsrModels.defaultCacheDirectory(for: version)
        guard !AsrModels.modelsExist(at: cache, version: version) else { return }
        guard parakeetProgress == nil else { return }
        watchParakeetSize()
        // So the footer button says what is happening from the first second,
        // rather than at the end of it.
        refresh()
        Task {
            do {
                _ = try await AsrModels.downloadAndLoad(version: version)
            } catch {
                parakeetStatus.stringValue = "download failed: \(error)"
            }
            parakeetProgress?.invalidate()
            parakeetProgress = nil
            parakeetBar.isHidden = true
            refresh()
        }
    }

    /// FluidAudio hands back no progress, so the progress is the cache
    /// directory growing. Approximate, and better than a spinner that could
    /// mean anything.
    private func watchParakeetSize() {
        parakeetProgress?.invalidate()
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetEngine.configuredVersion())
        parakeetBar.isHidden = false
        parakeetBar.doubleValue = 0
        parakeetProgress = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let mb = Self.megabytes(of: cache)
                self?.parakeetBar.doubleValue = Double(mb)
                self?.parakeetStatus.stringValue =
                    "\(mb) of about \(Self.parakeetMegabytes) MB"
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
            return "Both engines work it out from the audio. Naming a language "
                + "keeps a short or noisy meeting from being taken for another one."
        }
        guard code != "en" else { return "" }
        return "English meetings are recognised too — nothing to switch."
    }

    /// Check first, write second.
    ///
    /// The other order costs someone their working key: two characters typed
    /// into the field by accident used to replace a good key on disk, and the
    /// only sign was every later meeting failing to transcribe with HTTP 401.
    /// A key that isn't accepted never reaches the file.
    private func saveCloudKey() async {
        let target = pendingProvider ?? provider
        let key = cloudKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        cloudKeyStatus.stringValue = "checking…"

        let accepted = target == "openai"
            ? await SummaryKeyProbe.works(provider: .openAI, key: key)
            : await Self.assemblyKeyWorks(key)
        guard accepted else {
            cloudKeyStatus.stringValue = hasKey(for: target)
                ? "that key was refused — the saved one is untouched"
                : "that key was refused"
            return
        }
        let path = target == "openai" ? Config.openAIKeyPath : Config.assemblyAIKeyPath
        do {
            try Self.writeSecret(key, to: path)
        } catch {
            cloudKeyStatus.stringValue = "couldn't save the key: \(error)"
            return
        }
        cloudKey.stringValue = ""
        cloudKeyStatus.stringValue = "key works"
        // A key that works is the answer to the question the switch asked, so
        // it turns the cloud on rather than making the person click twice.
        provider = target
        pendingProvider = nil
        cloudSwitch.state = .on
        commitTranscription()
    }

    private func saveSummaryKey() async {
        let key = summaryKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let backend = selectedKeyBackend
        let provider: SummaryKeyProbe.Provider = backend == "anthropic-api" ? .anthropic : .openAI
        let path = backend == "anthropic-api"
            ? Config.anthropicKeyPath
            : Config.openAIKeyPath
        summaryKeyStatus.stringValue = "checking…"
        guard await SummaryKeyProbe.works(provider: provider, key: key) else {
            summaryKeyStatus.stringValue = "that key was refused — nothing was overwritten"
            return
        }
        do {
            try Self.writeSecret(key, to: path)
        } catch {
            summaryKeyStatus.stringValue = "couldn't save the key: \(error)"
            return
        }
        summaryKey.stringValue = ""
        summaryKeyStatus.stringValue = "key works"
        Config.update(path: ["summary", "backend"], value: backend)
        refresh()
    }

    /// A key is a secret: it goes to a file only its owner can read, never
    /// into the config file — which the settings window shows on screen. The
    /// directory is amanu's own and mode 0700, so a key pasted here can't be
    /// overwritten by some other tool that keeps its secrets in the same place.
    private static func writeSecret(_ value: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(value.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Ask AssemblyAI whether it knows this key, now, rather than finding out
    /// after a meeting. The cheapest authenticated call it has.
    private static func assemblyKeyWorks(_ key: String) async -> Bool {
        var request = URLRequest(
            url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
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

        summaryCards.card("claude-cli")?.status = Self.describe(claude)
        summaryCards.card("codex-cli")?.status = Self.describe(codex)
        summaryCards.card("claude-cli")?.showLink(claude == nil)
        summaryCards.card("codex-cli")?.showLink(codex == nil)

        summaryCards.card("ollama")?.status = models.map {
            $0.isEmpty ? "running, no models" : "running · \($0.prefix(2).joined(separator: ", "))"
        } ?? (ollama == nil ? "not here" : "installed, not running")
        summaryCards.card("ollama")?.showLink(ollama == nil)

        summaryToolRuns = [
            "claude-cli": claude?.runs == true,
            "codex-cli": codex?.runs == true,
            "ollama": models?.isEmpty == false,
        ]
        refresh()
    }

    private static func describe(_ tool: Tooling.Found?) -> String {
        guard let tool else { return "not here" }
        guard let version = tool.version else {
            return "found but it doesn't run from here"
        }
        return "answers · \(version)"
    }

    /// Whether the local model is on this Mac. A Mac that cannot run it at
    /// all is not missing it, so the question is answered yes there and the
    /// window stops asking.
    private var parakeetIsDownloaded: Bool {
        guard Platform.supportsLocalModels else { return true }
        let version = ParakeetEngine.configuredVersion()
        return AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// The two switches as the config file has them.
    private var transcriptionChoice: TranscriptionChoice {
        TranscriptionChoice.read(
            engine: Config.transcriptionEngine(),
            cloudProvider: Config.transcriptionCloudProvider(),
            enabled: Config.transcriptionEnabled(),
            localModels: Platform.supportsLocalModels)
    }

    /// Asked for, and not here. **On this Mac** is the whole question: both
    /// switches on is still asking for the local model, because that is the
    /// setting that transcribes when the network doesn't.
    private var parakeetIsWantedAndMissing: Bool {
        transcriptionChoice.needsLocalModel(downloaded: parakeetIsDownloaded)
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
                ? Config.openAIKey() == nil
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
            launchRow.update(.granted, note: "on")
        case .needsApproval:
            launchRow.update(
                .denied,
                detail: "macOS wants this allowed in Login Items.",
                action: "Open Settings")
        case .notRegistered:
            launchRow.update(.notAsked, detail: "So a meeting is never missed.")
        case .unavailable:
            launchRow.update(
                .notAsked,
                detail: "Only Amanu.app can register itself; this is a bare build.")
        }
        micRow.update(SetupPermissions.microphone())
        calendarRow.update(calendarGrant ?? SetupPermissions.calendar())

        switch systemAudio {
        case .heard:
            audioRow.update(
                .granted,
                note: SetupState.systemAudioHeardAt().map {
                    "heard the tone · \(Self.day.string(from: $0))"
                } ?? "heard the tone",
                action: "Test again")
        case .silent: audioRow.update(.denied, detail: "Recorded silence. Check the grant, or turn the volume up, and test again.")
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
        let livePrompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
        if liveModelStore.isReady(language: livePrompt) {
            liveStatus.stringValue = "downloaded"
            liveStatus.textColor = .systemGreen
        } else if !liveDownloading, Config.liveTranscriptionEnabled(), liveStatus.stringValue.isEmpty {
            liveStatus.stringValue = "about 600 MB — downloads when switched on"
        } else if !Config.liveTranscriptionEnabled() {
            liveStatus.stringValue = "optional"
        }

        let root = Config.resolveRoot(cliOverride: nil).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        recordingsPath.stringValue = root.hasPrefix(home)
            ? "~" + root.dropFirst(home.count)
            : root

        let summary = Config.summary()
        summariesOn.state = summary.enabled ? .on : .off
        let backendIsKey = summary.backend == "anthropic-api" || summary.backend == "openai-api"
        summaryCards.select(SetupSelection.summaryChoice(backend: summary.backend))
        if backendIsKey { keyProvider.selectedSegment = summary.backend == "openai-api" ? 1 : 0 }
        keyProviderChanged()
        for card in summaryCards.cards { card.isEnabled = summary.enabled }

        let autoRecordOn = (config["auto_record"] as? [String: Any])?["enabled"] as? Bool ?? true
        autoRecord.state = autoRecordOn ? .on : .off

        highlightNextGrant()
        onStateChange?()
    }

    /// The transcription section, redrawn from the config and from what is
    /// actually on disk: which keys exist, whether the local model is there.
    private func refreshTranscription() {
        let choice = transcriptionChoice
        provider = choice.provider
        pendingProvider = TranscriptionChoice.stillPending(pendingProvider) { [weak self] in
            self?.hasKey(for: $0) ?? false
        }

        cloudSwitch.state = choice.cloud ? .on : .off
        // The card under the key field is the one being answered, so a
        // provider waiting for a key is the one shown chosen.
        providerCards.select(pendingProvider ?? provider)

        for card in providerCards.cards {
            let known = hasKey(for: card.id)
            card.status = known ? "key works" : "no key yet"
            card.showLink(!known)
        }
        cloudKey.placeholderString = (pendingProvider ?? provider) == "openai"
            ? "sk-…" : "paste key"
        // Written on every pass rather than only into an empty label: a line
        // left over from the last question describes the wrong one.
        if let prompt = TranscriptionChoice.keyPrompt(
            pending: pendingProvider, inForce: provider, cloudOn: choice.cloud) {
            cloudKeyStatus.stringValue = prompt
        } else if cloudKeyStatus.stringValue == "checking…" {
            cloudKeyStatus.stringValue = ""
        }
        // The cards below carry the price and the key state, so the row speaks
        // only when a missing key is what holds the switch down.
        cloudStatus.stringValue = TranscriptionChoice.rowNeedsKey(
            pending: pendingProvider, cloudOn: choice.cloud) ? "needs a key" : ""
        keyLine.isHidden = pendingProvider == nil && hasKey(for: provider)

        localSwitch.isEnabled = Platform.supportsLocalModels
        localSwitch.state = choice.local ? .on : .off
        if !Platform.supportsLocalModels {
            parakeetStatus.stringValue = "needs Apple Silicon"
            parakeetStatus.textColor = .secondaryLabelColor
            parakeetBar.isHidden = true
        } else {
            let version = ParakeetEngine.configuredVersion()
            let downloaded = AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: version), version: version)
            if downloaded {
                parakeetStatus.stringValue = "downloaded"
                parakeetStatus.textColor = .systemGreen
                parakeetBar.isHidden = true
            } else if parakeetProgress == nil {
                parakeetStatus.stringValue =
                    choice.local ? "about \(Self.parakeetMegabytes) MB" : "free"
                parakeetStatus.textColor = .secondaryLabelColor
            }
        }
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

    /// What the setup window's primary button will do, or nil when there is
    /// nothing left to offer. The order is the order things must happen in:
    /// the agent first, because a grant given to the wrong process is worse
    /// than none.
    var nextAction: (() -> Void)? {
        if SetupPermissions.needsStartAtLogin {
            return { [weak self] in self?.startAtLogin() }
        }
        if SetupPermissions.microphone() == .notAsked {
            return { [weak self] in Task { await self?.askMicrophone() } }
        }
        if SetupPermissions.needsSystemAudioTest(systemAudio) {
            return { [weak self] in Task { await self?.testSystemAudio() } }
        }
        if parakeetIsWantedAndMissing, parakeetProgress == nil {
            return { [weak self] in self?.downloadParakeetIfNeeded() }
        }
        if Config.liveTranscriptionEnabled() {
            let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
            if !liveModelStore.isReady(language: prompt), !liveDownloading {
                return { [weak self] in self?.downloadLiveModel() }
            }
        }
        return nil
    }


    /// What the machine still owes, in the order it has to be dealt with.
    /// The setup window's footer is this list in a sentence and its button is
    /// `nextAction`; all three are here so they cannot disagree.
    var outstanding: [String] {
        var left: [String] = []
        if SetupPermissions.needsStartAtLogin { left.append("start at login") }
        if SetupPermissions.microphone() != .granted { left.append("microphone") }
        if systemAudio != .heard { left.append("system audio") }
        if parakeetIsWantedAndMissing { left.append("parakeet") }
        if Config.liveTranscriptionEnabled() {
            let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
            if !liveModelStore.isReady(language: prompt) { left.append("live model") }
        }
        // The window used to say everything was granted while the card it had
        // chosen to write the summaries said "not here" three inches above.
        if chosenSummaryIsMissing { left.append("something to summarise with") }
        return left
    }

    /// Whether a model is coming down right now — the work a host must not
    /// offer to start a second time.
    var isDownloading: Bool { liveDownloading || parakeetProgress != nil }

    /// What the setup window's primary button says, given where things stand.
    var nextActionTitle: String {
        if SetupPermissions.needsStartAtLogin {
            return LoginItem.status() == .needsApproval
                ? "Open Login Items"
                : "Start at login"
        }
        if SetupPermissions.microphone() == .notAsked { return "Allow microphone" }
        if SetupPermissions.needsSystemAudioTest(systemAudio) { return "Allow and test" }
        // Named separately from the live model because the two downloads
        // can be outstanding at once, and a button that says "Download
        // parakeet" while parakeet is downloading has nothing left to do
        // but close the window under the person reading it.
        if parakeetProgress != nil { return "Downloading parakeet…" }
        if outstanding.contains("parakeet") { return "Download parakeet" }
        if liveDownloading { return "Downloading live model…" }
        if outstanding.contains("live model") { return "Download live model" }
        return "Done"
    }
    private func report(_ row: AccessRow, _ message: String) {
        row.update(.denied, detail: message)
    }
}

// MARK: - one permission

/// A row in the Access list: where it stands, what it's for, and the one
/// button that changes it.
@MainActor
final class AccessRow: NSView, LayerTinted {
    var onAct: (() -> Void)?

    /// Whether this is the row being asked for right now; see `setAttention`.
    private var wantsAttention = false

    private let mark = NSImageView()
    private let title: NSTextField
    private let note = NSTextField(labelWithString: "")
    private let detail: NSTextField
    private let button: NSButton
    private let stack: NSStackView
    private let defaultDetail: String
    private let defaultAction: String
    private let grantedNote: String
    private let isOptional: Bool

    init(title: String, detail: String, action: String,
         grantedNote: String = "granted", optional: Bool = false) {
        self.title = NSTextField(labelWithString: title)
        self.detail = NSTextField(labelWithString: detail)
        self.defaultDetail = detail
        self.defaultAction = action
        self.grantedNote = grantedNote
        self.isOptional = optional
        button = NSButton(title: action, target: nil, action: nil)
        stack = NSStackView()
        super.init(frame: .zero)

        self.title.font = SetupLayout.titleFont
        note.font = SetupLayout.detailFont
        note.textColor = .tertiaryLabelColor
        wantsLayer = true

        self.detail.font = SetupLayout.detailFont
        self.detail.textColor = .secondaryLabelColor
        self.detail.lineBreakMode = .byWordWrapping
        self.detail.maximumNumberOfLines = 3
        self.detail.preferredMaxLayoutWidth = 460

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(act)

        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let heading = NSStackView(views: [self.title, note])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 6

        let text = NSStackView(views: [heading, self.detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        for view in [mark, text, SetupLayout.spacer(), button] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = SetupLayout.rowInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Every granted row carries one line and they have to look it; a row
        // still explaining itself has to keep the inset under its last line.
        // Both are the same arithmetic every other row gets.
        SetupLayout.fitRowHeight(stack)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func tintLayer() {
        layer?.backgroundColor = wantsAttention
            ? NSColor.systemOrange.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retint()
    }

    @objc private func act() { onAct?() }

    /// Say that something is happening, so a button that takes a second
    /// doesn't look like a button that did nothing.
    func working(_ message: String) {
        button.isEnabled = false
        detail.stringValue = message
    }

    /// The one row the person is being asked to act on right now is tinted.
    /// macOS shows one TCC dialog at a time, so more than one highlighted row
    /// would be pointing at work that cannot be done yet.
    func setAttention(_ on: Bool) {
        wantsAttention = on
        retint()
        title.textColor = on ? .systemOrange : .labelColor
        detail.textColor = on ? .systemOrange : .secondaryLabelColor
        if on {
            mark.image = NSImage(
                systemSymbolName: "exclamationmark.circle",
                accessibilityDescription: "needs your attention")
            mark.contentTintColor = .systemOrange
        }
    }

    /// `action` keeps a button on a granted row — for the one permission
    /// macOS will not report, where "granted" is a measurement someone may
    /// reasonably want to take again.
    func update(
        _ state: SetupPermissions.State,
        detail override: String? = nil,
        note noteOverride: String? = nil,
        action actionTitle: String? = nil
    ) {
        button.isEnabled = true
        button.title = actionTitle ?? defaultAction
        detail.stringValue = override ?? defaultDetail

        // A granted permission is one line: the title and how it stands. The
        // reasoning underneath is there to talk someone into granting it, and
        // it has nothing left to say once they have.
        let settled = state == .granted && override == nil
        detail.isHidden = settled || detail.stringValue.isEmpty
        // A row that is down to its title is one line, and sits in the middle
        // of the row like one; a row still explaining itself starts at the
        // top, beside its first line.
        stack.alignment = detail.isHidden ? .centerY : .top
        note.stringValue = noteOverride ?? {
            switch state {
            case .granted: return grantedNote
            case .notAsked, .unknown: return isOptional ? "optional" : ""
            case .denied: return ""
            }
        }()
        note.isHidden = note.stringValue.isEmpty

        switch state {
        case .granted:
            mark.image = NSImage(
                systemSymbolName: "checkmark.circle", accessibilityDescription: "granted")
            mark.contentTintColor = .systemGreen
            button.isHidden = actionTitle == nil
        case .denied:
            mark.image = NSImage(
                systemSymbolName: "exclamationmark.circle", accessibilityDescription: "denied")
            mark.contentTintColor = .systemOrange
            button.isHidden = false
            button.title = "Open Settings"
        case .notAsked, .unknown:
            mark.image = NSImage(
                systemSymbolName: "circle.dashed", accessibilityDescription: "not asked")
            mark.contentTintColor = .tertiaryLabelColor
            button.isHidden = false
        }
    }
}

// MARK: - one of several

/// A card in a row of mutually exclusive choices.
@MainActor
final class ChoiceCard: NSView, LayerTinted {
    let id: String
    var onSelect: ((String) -> Void)?

    private let radio = NSImageView()
    private let titleLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private var linkButton: NSButton?
    private var selected = false

    var status: String {
        get { statusLabel.stringValue }
        set {
            statusLabel.stringValue = newValue
            statusLabel.isHidden = newValue.isEmpty
            // "answers", "downloaded", "key works" are the states worth
            // seeing across the window; everything else is a note.
            let good = ["answers", "downloaded", "key works", "running"]
            works = good.contains(where: newValue.hasPrefix)
            colourStatus()
        }
    }

    /// Whether the last thing the machine said about this card was good news.
    private var works = false

    /// An unchosen card may report "not here" in passing — it is one of the
    /// options, and that is what there is to say about it. The chosen one may
    /// not: that is the meeting that will come back without a summary, so it
    /// is said in the colour of something to attend to.
    private func colourStatus() {
        statusLabel.textColor = works
            ? .systemGreen
            : (selected ? .systemOrange : .secondaryLabelColor)
    }

    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1 : 0.45 }
    }

    var isSelected: Bool {
        get { selected }
        set {
            selected = newValue
            radio.image = NSImage(
                systemSymbolName: newValue ? "largecircle.fill.circle" : "circle",
                accessibilityDescription: newValue ? "chosen" : "not chosen")
            radio.contentTintColor = newValue ? .controlAccentColor : .tertiaryLabelColor
            layer?.borderWidth = newValue ? 1.5 : 1
            retint()
            colourStatus()
        }
    }

    init(id: String, title: String, detail: String, accessories: [NSView] = [],
         compact: Bool = false) {
        self.id = id
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        titleLabel.font = SetupLayout.titleFont
        radio.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        radio.widthAnchor.constraint(equalToConstant: 17).isActive = true
        isSelected = false

        let heading = NSStackView(views: [radio, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 7

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = SetupLayout.detailFont
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = compact ? .byTruncatingTail : .byWordWrapping
        detailLabel.maximumNumberOfLines = compact ? 1 : 4
        detailLabel.preferredMaxLayoutWidth = 190

        statusLabel.font = SetupLayout.statusFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.isHidden = true

        linkButton = accessories.compactMap { $0 as? NSButton }.last { $0.bezelStyle == .inline }

        wantsLayer = true
        layer?.cornerRadius = SetupLayout.corner
        layer?.borderWidth = 1
        retint()

        let stack = compact
            ? NSStackView(views: [heading, detailLabel, NSView(), statusLabel] + accessories)
            : NSStackView(views: [heading, detailLabel, statusLabel] + accessories)
        stack.orientation = compact ? .horizontal : .vertical
        stack.alignment = compact ? .centerY : .leading
        stack.spacing = compact ? 8 : 7
        stack.edgeInsets = compact ? SetupLayout.rowInsets : SetupLayout.cardInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        guard !compact else { return }
        for accessory in accessories where accessory is NSTextField || accessory is NSSegmentedControl {
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func tintLayer() {
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        retint()
    }

    /// The install link only belongs on a card for something that isn't here.
    func showLink(_ show: Bool) { linkButton?.isHidden = !show }

    /// `hitTest` is asked in the *superview's* coordinates, so the test has to
    /// be against `frame`. Against `bounds` it silently answers "not mine" for
    /// every card that isn't at the origin of its row — which is how a row of
    /// three cards ends up with only the leftmost one responding to a click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        guard let hit = super.hitTest(point) else { return self }
        if hit === self || containsInteractiveControl(hit) { return hit }
        return self
    }

    private func containsInteractiveControl(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton || current is NSSegmentedControl {
                return true
            }
            if let field = current as? NSTextField, field.isEditable {
                return true
            }
            view = current.superview
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?(id)
    }
}

/// A set of cards where exactly one is chosen. AppKit only groups radio
/// buttons that share a superview, and these deliberately don't — so the
/// grouping is done here, in the open.
@MainActor
private final class ChoiceGroup {
    private(set) var cards: [ChoiceCard] = []
    var onChange: ((String) -> Void)?

    var selected: String? { cards.first { $0.isSelected }?.id }

    func adopt(_ cards: [ChoiceCard]) {
        self.cards = cards
        for card in cards {
            card.onSelect = { [weak self] id in
                self?.select(id)
                self?.onChange?(id)
            }
        }
    }

    func card(_ id: String) -> ChoiceCard? { cards.first { $0.id == id } }

    func select(_ id: String?) {
        for card in cards { card.isSelected = card.id == id }
    }
}
