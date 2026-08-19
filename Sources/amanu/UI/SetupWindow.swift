import AppKit
import FluidAudio
import Foundation

/// The window a new installation opens by itself: the permissions macOS will
/// otherwise ask for at the worst possible moment, and the two choices amanu
/// can't sensibly make for you — what writes the transcript, and what writes
/// the summary.
///
/// It is a window rather than a terminal wizard for a reason that isn't
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
final class SetupWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// window is worth losing a meeting for.
    var isRecording: (() -> Bool)?
    /// Called when the window has done everything it can and been dismissed.
    var onFinished: (() -> Void)?

    private let panel: NSWindow

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

    private let engineCards = ChoiceGroup()
    private let language = NSTextField()
    private let keepAudio = NSButton(
        checkboxWithTitle: "Keep the audio after transcribing", target: nil, action: nil)
    private let liveTranscription = NSSwitch()
    private let liveStatus = NSTextField(labelWithString: "")
    private let liveModelStore = LiveTranscriptionModelStore()
    private var liveDownloadTask: Task<Void, Never>?
    private var liveDownloading = false
    private let assemblyKey = NSSecureTextField()
    private let assemblyStatus = NSTextField(labelWithString: "")
    private let parakeetStatus = NSTextField(labelWithString: "")
    private let parakeetDownload = NSButton(title: "Download", target: nil, action: nil)
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

    private let footerNote = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "Done", target: nil, action: nil)

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "amanu setup"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 640, height: 460)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = SetupLayout.sectionGap
        form.edgeInsets = NSEdgeInsets(
            top: 22, left: SetupLayout.gutter, bottom: 22, right: SetupLayout.gutter)

        form.addArrangedSubview(SetupLayout.section(
            "Access",
            content: SetupLayout.box([launchRow, micRow, audioRow, calendarRow])))

        var transcription: [NSView] = [transcriptionCards(), languageRow()]
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
        // without anyone opening this window again.
        form.addArrangedSubview(SetupLayout.box([autoRecordRow()]))

        for view in form.arrangedSubviews {
            view.widthAnchor.constraint(
                equalTo: form.widthAnchor, constant: -2 * SetupLayout.gutter).isActive = true
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        footerNote.font = .systemFont(ofSize: 12)
        footerNote.textColor = .secondaryLabelColor
        footerNote.lineBreakMode = .byTruncatingTail

        let later = NSButton(title: "Later", target: self, action: #selector(laterClicked))
        later.bezelStyle = .rounded
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(primaryClicked)

        let footer = NSStackView(views: [footerNote, later, primary])
        footer.orientation = .horizontal
        footer.spacing = 12
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerNote.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let divider = SetupLayout.hairline()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(divider)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        panel.contentView = content
        panel.center()

        wireActions()
        refresh()
    }

    func show() {
        refresh()
        // Detection runs off the main thread: finding `claude` can mean
        // starting the login shell, and a window that freezes while it asks
        // would be a worse first impression than one that fills in.
        Task { await detectTools() }
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return false
    }

    // MARK: - building

    private func transcriptionCards() -> NSView {
        let auto = ChoiceCard(
            id: "auto",
            title: "Whichever works",
            detail: "AssemblyAI when there's a key and a network, parakeet otherwise.")

        parakeetStatus.font = SetupLayout.statusFont
        parakeetStatus.textColor = .secondaryLabelColor
        parakeetStatus.lineBreakMode = .byWordWrapping
        parakeetStatus.maximumNumberOfLines = 2
        parakeetDownload.bezelStyle = .rounded
        parakeetDownload.controlSize = .small
        parakeetDownload.target = self
        parakeetDownload.action = #selector(downloadParakeetClicked)
        // FluidAudio reports no progress, so the bar is the cache directory
        // growing towards the model's known size. Approximate, and better
        // than a spinner that could mean anything.
        parakeetBar.style = .bar
        parakeetBar.isIndeterminate = false
        parakeetBar.controlSize = .small
        parakeetBar.minValue = 0
        parakeetBar.maxValue = 600
        parakeetBar.isHidden = true
        let local = ChoiceCard(
            id: "parakeet",
            title: "On this Mac",
            detail: "parakeet. Nothing leaves the machine.",
            accessories: [parakeetBar, parakeetStatus, parakeetDownload])

        assemblyKey.placeholderString = "paste key"
        assemblyKey.font = SetupLayout.detailFont
        assemblyKey.delegate = self
        assemblyStatus.font = SetupLayout.statusFont
        assemblyStatus.textColor = .secondaryLabelColor
        assemblyStatus.lineBreakMode = .byWordWrapping
        assemblyStatus.maximumNumberOfLines = 2
        let cloud = ChoiceCard(
            id: "assemblyai",
            title: "AssemblyAI",
            detail: Platform.supportsLocalModels
                ? "Tells apart people sharing one channel. Audio leaves the Mac."
                : "The engine this Mac can run — the local one needs Apple "
                    + "Silicon. Audio leaves the Mac.",
            accessories: [
                assemblyKey, assemblyStatus,
                link("Get a key", "https://www.assemblyai.com/dashboard/signup"),
            ])

        // One card, not three, on an Intel Mac: the other two are the same
        // local model under different names, and it cannot run here.
        engineCards.adopt(Platform.supportsLocalModels ? [auto, local, cloud] : [cloud])
        engineCards.onChange = { [weak self] id in
            Config.update(path: ["transcription", "engine"], value: id == "auto" ? nil : id)
            self?.refresh()
        }
        return SetupLayout.cards(engineCards.cards)
    }

    private func languageRow() -> NSView {
        let label = NSTextField(labelWithString: "Meetings are mostly in")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        language.placeholderString = Self.systemLanguage ?? "ru"
        language.delegate = self
        language.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [label, language, NSView()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
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

    private func keepAudioRow() -> NSView {
        keepAudio.target = self
        keepAudio.action = #selector(keepAudioChanged)
        keepAudio.font = SetupLayout.titleFont
        return SetupLayout.row(title: keepAudio)
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

    private static var systemLanguage: String? {
        Locale.current.language.languageCode?.identifier
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

    @objc private func keepAudioChanged() {
        Config.update(path: ["keep_audio"], value: keepAudio.state == .on ? true : nil)
    }

    @objc private func liveTranscriptionToggled() {
        let enabled = liveTranscription.state == .on
        Config.update(path: ["live_transcription", "enabled"], value: enabled ? true : nil)
        if enabled {
            commitLanguage()
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
        let prompt = LiveTranscriptionLanguage.prompt(for:
            language.stringValue.isEmpty ? Config.transcriptionLanguage() : language.stringValue)
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
        if state == .denied { SetupPermissions.openSettings(.calendar) }
        refresh()
    }

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

    @objc private func downloadParakeetClicked() {
        parakeetDownload.isEnabled = false
        watchParakeetSize()
        Task {
            let version = ParakeetEngine.configuredVersion()
            do {
                _ = try await AsrModels.downloadAndLoad(version: version)
            } catch {
                parakeetStatus.stringValue = "download failed: \(error)"
            }
            parakeetProgress?.invalidate()
            parakeetProgress = nil
            parakeetBar.isHidden = true
            parakeetDownload.isEnabled = true
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
                self?.parakeetStatus.stringValue = "\(mb) of about 600 MB"
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

    @objc private func laterClicked() {
        finish()
    }

    @objc private func primaryClicked() {
        // The button does the next unfinished thing, and only closes when
        // there is nothing left it can do from here.
        if let next = nextAction {
            next()
            return
        }
        finish()
    }

    /// Setup is marked done on the way out however it was dismissed. Asking
    /// once is the promise; a window that comes back every launch until every
    /// box is ticked would be nagging, and `amanu doctor` still says what is
    /// missing.
    private func finish() {
        commitLanguage()
        SetupState.markCompleted()
        parakeetProgress?.invalidate()
        parakeetProgress = nil
        panel.orderOut(nil)
        onFinished?()
    }

    // MARK: - text fields

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === language { commitLanguage() }
        if field === assemblyKey { Task { await saveAssemblyKey() } }
        if field === summaryKey { Task { await saveSummaryKey() } }
    }

    private func commitLanguage() {
        let code = language.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Config.update(path: ["transcription", "language"], value: code.isEmpty ? nil : code)
    }

    /// Check first, write second.
    ///
    /// The other order costs someone their working key: two characters typed
    /// into the field by accident used to replace a good key on disk, and the
    /// only sign was every later meeting failing to transcribe with HTTP 401.
    /// A key that isn't accepted never reaches the file.
    private func saveAssemblyKey() async {
        let key = assemblyKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        assemblyStatus.stringValue = "checking…"
        guard await Self.assemblyKeyWorks(key) else {
            assemblyStatus.stringValue = Config.assemblyAIKey() == nil
                ? "that key was refused"
                : "that key was refused — the saved one is untouched"
            return
        }
        do {
            try Self.writeSecret(key, to: Config.assemblyAIKeyPath)
        } catch {
            assemblyStatus.stringValue = "couldn't save the key: \(error)"
            return
        }
        assemblyKey.stringValue = ""
        assemblyStatus.stringValue = "key works"
        refresh()
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

    private func detectTools() async {
        // The window is reopened for exactly one reason: something about the
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
        refresh()
    }

    private static func describe(_ tool: Tooling.Found?) -> String {
        guard let tool else { return "not here" }
        guard let version = tool.version else {
            return "found but it doesn't run from here"
        }
        return "answers · \(version)"
    }

    // MARK: - refresh

    /// Redraw everything from the machine and the config file. Cheap: no
    /// subprocesses, no network — those write into fields this only reads.
    private func refresh() {
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
        calendarRow.update(SetupPermissions.calendar())

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
        // With only the cloud card on screen, a configured "auto" — which
        // resolves to that engine here anyway — is shown as that card rather
        // than as nothing selected at all.
        engineCards.select(
            Platform.supportsLocalModels ? Config.transcriptionEngine() : "assemblyai")
        if language.stringValue.isEmpty, let stored = Config.transcriptionLanguage() {
            language.stringValue = stored
        }
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

        if Platform.supportsLocalModels {
            let version = ParakeetEngine.configuredVersion()
            let downloaded = AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: version), version: version)
            parakeetDownload.isHidden = downloaded
            if downloaded {
                parakeetStatus.stringValue = "downloaded"
                parakeetStatus.textColor = .systemGreen
                parakeetBar.isHidden = true
            } else if parakeetProgress == nil {
                parakeetStatus.stringValue = "about 600 MB"
                parakeetStatus.textColor = .secondaryLabelColor
            }
        }

        if Config.assemblyAIKey() != nil, assemblyStatus.stringValue.isEmpty {
            assemblyStatus.stringValue = "key found"
        }

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
        updateFooter()
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

    /// What the primary button will do, or nil when the window has nothing
    /// left to offer. The order is the order things must happen in: the agent
    /// first, because a grant given to the wrong process is worse than none.
    private var nextAction: (() -> Void)? {
        if SetupPermissions.needsStartAtLogin {
            return { [weak self] in self?.startAtLogin() }
        }
        if SetupPermissions.microphone() == .notAsked {
            return { [weak self] in Task { await self?.askMicrophone() } }
        }
        if SetupPermissions.needsSystemAudioTest(systemAudio) {
            return { [weak self] in Task { await self?.testSystemAudio() } }
        }
        if Config.liveTranscriptionEnabled() {
            let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
            if !liveModelStore.isReady(language: prompt), !liveDownloading {
                return { [weak self] in self?.downloadLiveModel() }
            }
        }
        return nil
    }

    private func updateFooter() {
        var outstanding: [String] = []
        if SetupPermissions.needsStartAtLogin { outstanding.append("start at login") }
        if SetupPermissions.microphone() != .granted { outstanding.append("microphone") }
        if systemAudio != .heard { outstanding.append("system audio") }
        if Config.liveTranscriptionEnabled() {
            let prompt = LiveTranscriptionLanguage.prompt(for: Config.transcriptionLanguage())
            if !liveModelStore.isReady(language: prompt) { outstanding.append("live model") }
        }

        footerNote.stringValue = outstanding.isEmpty
            ? "Everything amanu needs is granted."
            : (outstanding.count == 1
                ? "One thing left: \(outstanding[0])"
                : "Left: \(outstanding.joined(separator: ", "))")

        primary.title = {
            if SetupPermissions.needsStartAtLogin {
                return LoginItem.status() == .needsApproval
                    ? "Open Login Items"
                    : "Start at login"
            }
            if SetupPermissions.microphone() == .notAsked { return "Allow microphone" }
            if SetupPermissions.needsSystemAudioTest(systemAudio) { return "Allow and test" }
            if liveDownloading { return "Downloading live model…" }
            if outstanding.contains("live model") { return "Download live model" }
            return "Done"
        }()
        primary.isEnabled = !liveDownloading
    }

    private func report(_ row: AccessRow, _ message: String) {
        row.update(.denied, detail: message)
    }
}

// MARK: - one permission

/// A row in the Access list: where it stands, what it's for, and the one
/// button that changes it.
@MainActor
private final class AccessRow: NSView, LayerTinted {
    var onAct: (() -> Void)?

    /// Whether this is the row being asked for right now; see `setAttention`.
    private var wantsAttention = false

    private let mark = NSImageView()
    private let title: NSTextField
    private let note = NSTextField(labelWithString: "")
    private let detail: NSTextField
    private let button: NSButton
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

        let stack = NSStackView(views: [mark, text, NSView(), button])
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
            statusLabel.textColor = good.contains(where: newValue.hasPrefix)
                ? .systemGreen
                : .secondaryLabelColor
        }
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
