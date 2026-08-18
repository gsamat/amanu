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
    /// Whether a recording is in progress — installing the LaunchAgent
    /// restarts amanu, and that must never happen mid-meeting.
    var isRecording: (() -> Bool)?
    /// Called when the window has done everything it can and been dismissed.
    var onFinished: (() -> Void)?

    private let panel: NSWindow

    private let launchRow = AccessRow(
        title: "Start at login",
        detail: "System audio is only ever granted to the copy launchd starts.",
        action: "Install")
    private let micRow = AccessRow(
        title: "Microphone",
        detail: "Your side of the call.",
        action: "Allow")
    private let audioRow = AccessRow(
        title: "System audio",
        detail: "Everyone else's side. Without it they are recorded as silence.",
        action: "Allow and test")
    private let calendarRow = AccessRow(
        title: "Calendar",
        detail: "Optional. Names the folder and the speakers from the invitees.",
        action: "Allow")

    private let engineCards = ChoiceGroup()
    private let language = NSTextField()
    private let keepAudio = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let assemblyKey = NSSecureTextField()
    private let assemblyStatus = NSTextField(labelWithString: "")
    private let parakeetStatus = NSTextField(labelWithString: "")
    private let parakeetDownload = NSButton(title: "Download", target: nil, action: nil)
    private var parakeetProgress: Timer?

    private let summariesOn = NSSwitch()
    private let summaryCards = ChoiceGroup()
    private let keyProvider = NSSegmentedControl(
        labels: ["Anthropic", "OpenAI"], trackingMode: .selectOne, target: nil, action: nil)
    private let summaryKey = NSSecureTextField()
    private let summaryKeyStatus = NSTextField(labelWithString: "")
    private lazy var summaryKeyLink = link(
        "Get a key", "https://console.anthropic.com/settings/keys")

    private let autoRecord = NSSwitch()

    private let footerNote = NSTextField(labelWithString: "")
    private let primary = NSButton(title: "Done", target: nil, action: nil)

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "amanu setup"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 600, height: 420)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        form.addArrangedSubview(header("Access"))
        form.addArrangedSubview(box([launchRow, micRow, audioRow, calendarRow]))

        form.setCustomSpacing(22, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(header("Transcription"))
        form.addArrangedSubview(transcriptionCards())
        form.addArrangedSubview(languageRow())
        form.addArrangedSubview(box([keepAudioRow()]))

        form.setCustomSpacing(22, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(summariesHeader())
        form.addArrangedSubview(summaryChoices())
        form.addArrangedSubview(box([ollamaRow()]))

        form.setCustomSpacing(22, after: form.arrangedSubviews.last!)
        form.addArrangedSubview(box([autoRecordRow()]))

        for view in form.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -40).isActive = true
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

        footerNote.font = .systemFont(ofSize: 11)
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
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerNote.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
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

    private func header(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    /// Rows in a bordered container, hairlines between them — the shape macOS
    /// uses everywhere for a list of settings.
    private func box(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.wantsLayer = true
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.layer?.cornerRadius = 6

        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(hairline()) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func transcriptionCards() -> NSView {
        let auto = ChoiceCard(
            id: "auto",
            title: "Whichever works",
            detail: "AssemblyAI when there's a key and a network, parakeet otherwise.")

        parakeetStatus.font = .systemFont(ofSize: 11)
        parakeetStatus.textColor = .secondaryLabelColor
        parakeetStatus.lineBreakMode = .byWordWrapping
        parakeetStatus.maximumNumberOfLines = 2
        parakeetDownload.bezelStyle = .rounded
        parakeetDownload.controlSize = .small
        parakeetDownload.target = self
        parakeetDownload.action = #selector(downloadParakeetClicked)
        let local = ChoiceCard(
            id: "parakeet",
            title: "On this Mac",
            detail: "parakeet. Nothing leaves the machine.",
            accessories: [parakeetStatus, parakeetDownload])

        assemblyKey.placeholderString = "paste key"
        assemblyKey.font = .systemFont(ofSize: 11)
        assemblyKey.delegate = self
        assemblyStatus.font = .systemFont(ofSize: 11)
        assemblyStatus.textColor = .secondaryLabelColor
        assemblyStatus.lineBreakMode = .byWordWrapping
        assemblyStatus.maximumNumberOfLines = 2
        let cloud = ChoiceCard(
            id: "assemblyai",
            title: "AssemblyAI",
            detail: "Tells apart people sharing one channel. Audio leaves the Mac.",
            accessories: [assemblyKey, assemblyStatus, link("Get a key", "https://www.assemblyai.com/dashboard/signup")])

        engineCards.adopt([auto, local, cloud])
        engineCards.onChange = { [weak self] id in
            Config.update(path: ["transcription", "engine"], value: id == "auto" ? nil : id)
            self?.refresh()
        }
        return row(engineCards.cards)
    }

    private func languageRow() -> NSView {
        let label = NSTextField(labelWithString: "Meetings are mostly in")
        language.placeholderString = Self.systemLanguage ?? "ru"
        language.delegate = self
        language.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [label, language])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func keepAudioRow() -> NSView {
        keepAudio.target = self
        keepAudio.action = #selector(keepAudioChanged)
        return settingRow(
            control: keepAudio,
            title: "Keep the audio after transcribing",
            detail: "Off, a session keeps its transcript and its summary — about a gigabyte "
                + "an hour lighter, and nothing left to transcribe again if the result is wrong.")
    }

    private func summariesHeader() -> NSView {
        summariesOn.target = self
        summariesOn.action = #selector(summariesToggled)
        let stack = NSStackView(views: [header("Summaries"), NSView(), summariesOn])
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
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

        keyProvider.selectedSegment = 0
        keyProvider.target = self
        keyProvider.action = #selector(keyProviderChanged)
        summaryKey.placeholderString = "sk-ant-…"
        summaryKey.font = .systemFont(ofSize: 11)
        summaryKey.delegate = self
        summaryKeyStatus.font = .systemFont(ofSize: 11)
        summaryKeyStatus.textColor = .secondaryLabelColor
        summaryKeyStatus.lineBreakMode = .byWordWrapping
        summaryKeyStatus.maximumNumberOfLines = 2
        let key = ChoiceCard(
            id: "api-key",
            title: "My own key",
            detail: "Billed per meeting, needs no CLI.",
            accessories: [keyProvider, summaryKey, summaryKeyStatus, summaryKeyLink])

        summaryCards.adopt([claude, codex, key])
        summaryCards.onChange = { [weak self] id in
            guard let self else { return }
            Config.update(path: ["summary", "backend"], value: SetupSelection.summaryBackend(
                choice: id, keyBackend: self.selectedKeyBackend))
            self.refresh()
        }
        return row(summaryCards.cards)
    }

    private func ollamaRow() -> NSView {
        let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(ollamaChosen))
        let title = NSTextField(labelWithString: "ollama")
        let detail = NSTextField(labelWithString: "— no account, no network, weaker summaries")
        detail.textColor = .secondaryLabelColor
        ollamaState.font = .systemFont(ofSize: 11)
        ollamaState.textColor = .secondaryLabelColor
        ollamaRadio = radio

        let stack = NSStackView(views: [radio, title, detail, NSView(), ollamaState])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return stack
    }

    private func autoRecordRow() -> NSView {
        autoRecord.target = self
        autoRecord.action = #selector(autoRecordToggled)
        return settingRow(
            control: autoRecord,
            title: "Start recording by itself when a call app takes the mic",
            detail: "And stop when it lets go. Recordings shorter than a minute are thrown away.")
    }

    /// A switch on the left, a title and a line of explanation beside it.
    private func settingRow(control: NSView, title: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3
        detailLabel.preferredMaxLayoutWidth = 520

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let stack = NSStackView(views: [control, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        return stack
    }

    private func row(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = 10
        return stack
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(linkClicked(_:)))
        button.bezelStyle = .inline
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(url)
        return button
    }

    private let ollamaState = NSTextField(labelWithString: "")
    private var ollamaRadio: NSButton?

    private static var systemLanguage: String? {
        Locale.current.language.languageCode?.identifier
    }

    // MARK: - actions

    private func wireActions() {
        launchRow.onAct = { [weak self] in self?.installAgent() }
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

    @objc private func autoRecordToggled() {
        Config.update(
            path: ["auto_record", "enabled"], value: autoRecord.state == .on ? nil : false)
    }

    @objc private func summariesToggled() {
        Config.update(path: ["summary", "enabled"], value: summariesOn.state == .on ? nil : false)
        refresh()
    }

    @objc private func ollamaChosen() {
        Config.update(path: ["summary", "backend"], value: "ollama")
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

    /// Installing the agent hands amanu to launchd — and this process, started
    /// some other way, has to get out of the way of the one launchd starts.
    /// That is the point of the exercise rather than a side effect: only the
    /// launchd copy has an identity macOS can attach a system-audio grant to.
    private func installAgent() {
        if isRecording?() == true {
            report(launchRow, "not while a recording is running — stop it and try again")
            return
        }
        do {
            try Install.installAgent()
        } catch {
            report(launchRow, "couldn't install: \(error)")
            return
        }
        refresh()

        let alert = NSAlert()
        alert.messageText = "amanu will restart"
        alert.informativeText = """
            launchd has its own copy running now. This one is closing so the two \
            don't both record; the setup window opens again in the new one.
            """
        alert.addButton(withTitle: "Restart")
        alert.runModal()
        NSApp.terminate(nil)
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
        switch result {
        case .heard:
            break
        case .silent, .refused:
            SetupPermissions.openSettings(.systemAudio)
        }
        refresh()
    }

    private var systemAudio: SetupPermissions.SystemAudioResult?

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
        parakeetProgress = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let mb = Self.megabytes(of: cache)
                self?.parakeetStatus.stringValue = "downloading — \(mb) of about 600 MB"
            }
        }
    }

    private static func megabytes(of dir: URL) -> String {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return "0 MB" }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return "\(total / 1_048_576) MB"
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

    private func saveAssemblyKey() async {
        let key = assemblyKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Self.writeSecret(key, to: Config.assemblyAIDefaultKeyPath)
        } catch {
            assemblyStatus.stringValue = "couldn't save the key: \(error)"
            return
        }
        assemblyKey.stringValue = ""
        assemblyStatus.stringValue = "checking…"
        assemblyStatus.stringValue = await Self.assemblyKeyWorks(key)
            ? "key works"
            : "that key was refused"
        refresh()
    }

    private func saveSummaryKey() async {
        let key = summaryKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let backend = selectedKeyBackend
        let provider: SummaryKeyProbe.Provider = backend == "anthropic-api" ? .anthropic : .openAI
        let path = backend == "anthropic-api"
            ? Config.anthropicDefaultKeyPath
            : Config.openAIDefaultKeyPath
        do {
            try Self.writeSecret(key, to: path)
        } catch {
            summaryKeyStatus.stringValue = "couldn't save the key: \(error)"
            return
        }
        summaryKey.stringValue = ""
        summaryKeyStatus.stringValue = "checking…"
        summaryKeyStatus.stringValue = await SummaryKeyProbe.works(provider: provider, key: key)
            ? "key works"
            : "that key was refused"
        Config.update(path: ["summary", "backend"], value: backend)
        refresh()
    }

    /// A key is a secret: it goes to a file only its owner can read, never
    /// into the config file — which the settings window shows on screen.
    private static func writeSecret(_ value: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
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
        // Off the main actor: `Tooling` may start a login shell and run the
        // binaries it finds, which is seconds, not milliseconds.
        let claude = await Task.detached { Tooling.probe("claude") }.value
        let codex = await Task.detached { Tooling.probe("codex") }.value
        let models = await Tooling.ollamaModels()

        summaryCards.card("claude-cli")?.status = Self.describe(claude)
        summaryCards.card("codex-cli")?.status = Self.describe(codex)
        summaryCards.card("claude-cli")?.showLink(claude == nil)
        summaryCards.card("codex-cli")?.showLink(codex == nil)

        ollamaState.stringValue = models.map {
            $0.isEmpty ? "running, no models" : "running · \($0.prefix(2).joined(separator: ", "))"
        } ?? "not running"
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
        launchRow.update(
            SetupPermissions.needsLaunchAgentHandoff ? .notAsked : .granted,
            detail: SetupPermissions.launchAgentInstalled && !SetupPermissions.runningUnderLaunchd
                ? "Installed, but this copy isn't the one launchd started."
                : nil)
        micRow.update(SetupPermissions.microphone())
        calendarRow.update(SetupPermissions.calendar())

        switch systemAudio {
        case .heard: audioRow.update(.granted, detail: "Played a tone and heard it back.")
        case .silent: audioRow.update(.denied, detail: "Recorded silence. Check the grant, or turn the volume up, and test again.")
        case .refused(let why): audioRow.update(.denied, detail: why)
        case nil: audioRow.update(.notAsked)
        }

        let config = Config.raw()
        engineCards.select(Config.transcriptionEngine())
        if language.stringValue.isEmpty, let stored = Config.transcriptionLanguage() {
            language.stringValue = stored
        }
        keepAudio.state = Config.keepAudio() ? .on : .off

        let version = ParakeetEngine.configuredVersion()
        let downloaded = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: version), version: version)
        parakeetDownload.isHidden = downloaded
        if downloaded { parakeetStatus.stringValue = "downloaded" }
        else if parakeetProgress == nil { parakeetStatus.stringValue = "about 600 MB" }

        if Config.assemblyAIKey() != nil, assemblyStatus.stringValue.isEmpty {
            assemblyStatus.stringValue = "key found"
        }

        let summary = Config.summary()
        summariesOn.state = summary.enabled ? .on : .off
        let backendIsKey = summary.backend == "anthropic-api" || summary.backend == "openai-api"
        summaryCards.select(SetupSelection.summaryChoice(backend: summary.backend))
        if backendIsKey { keyProvider.selectedSegment = summary.backend == "openai-api" ? 1 : 0 }
        keyProviderChanged()
        ollamaRadio?.state = summary.backend == "ollama" ? .on : .off
        for card in summaryCards.cards { card.isEnabled = summary.enabled }
        ollamaRadio?.isEnabled = summary.enabled

        let autoRecordOn = (config["auto_record"] as? [String: Any])?["enabled"] as? Bool ?? true
        autoRecord.state = autoRecordOn ? .on : .off

        updateFooter()
    }

    /// What the primary button will do, or nil when the window has nothing
    /// left to offer. The order is the order things must happen in: the agent
    /// first, because a grant given to the wrong process is worse than none.
    private var nextAction: (() -> Void)? {
        if SetupPermissions.needsLaunchAgentHandoff {
            return { [weak self] in self?.installAgent() }
        }
        if SetupPermissions.microphone() == .notAsked {
            return { [weak self] in Task { await self?.askMicrophone() } }
        }
        if SetupPermissions.needsSystemAudioTest(systemAudio) {
            return { [weak self] in Task { await self?.testSystemAudio() } }
        }
        return nil
    }

    private func updateFooter() {
        var outstanding: [String] = []
        if SetupPermissions.needsLaunchAgentHandoff { outstanding.append("start at login") }
        if SetupPermissions.microphone() != .granted { outstanding.append("microphone") }
        if systemAudio != .heard { outstanding.append("system audio") }

        footerNote.stringValue = outstanding.isEmpty
            ? "Everything amanu needs is granted."
            : (outstanding.count == 1
                ? "One thing left: \(outstanding[0])"
                : "Left: \(outstanding.joined(separator: ", "))")

        primary.title = {
            if SetupPermissions.needsLaunchAgentHandoff {
                return SetupPermissions.launchAgentInstalled ? "Restart" : "Install"
            }
            if SetupPermissions.microphone() == .notAsked { return "Allow microphone" }
            if SetupPermissions.needsSystemAudioTest(systemAudio) { return "Allow and test" }
            return "Done"
        }()
    }

    private func report(_ row: AccessRow, _ message: String) {
        row.update(.denied, detail: message)
    }
}

// MARK: - one permission

/// A row in the Access list: where it stands, what it's for, and the one
/// button that changes it.
@MainActor
private final class AccessRow: NSView {
    var onAct: (() -> Void)?

    private let mark = NSImageView()
    private let title: NSTextField
    private let detail: NSTextField
    private let button: NSButton
    private let defaultDetail: String

    init(title: String, detail: String, action: String) {
        self.title = NSTextField(labelWithString: title)
        self.detail = NSTextField(labelWithString: detail)
        self.defaultDetail = detail
        button = NSButton(title: action, target: nil, action: nil)
        super.init(frame: .zero)

        self.detail.font = .systemFont(ofSize: 11)
        self.detail.textColor = .secondaryLabelColor
        self.detail.lineBreakMode = .byWordWrapping
        self.detail.maximumNumberOfLines = 3
        self.detail.preferredMaxLayoutWidth = 420

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(act)

        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let text = NSStackView(views: [self.title, self.detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let stack = NSStackView(views: [mark, text, NSView(), button])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
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

    @objc private func act() { onAct?() }

    /// Say that something is happening, so a button that takes a second
    /// doesn't look like a button that did nothing.
    func working(_ message: String) {
        button.isEnabled = false
        detail.stringValue = message
    }

    func update(_ state: SetupPermissions.State, detail override: String? = nil) {
        button.isEnabled = true
        detail.stringValue = override ?? defaultDetail

        switch state {
        case .granted:
            mark.image = NSImage(
                systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "granted")
            mark.contentTintColor = .systemGreen
            button.isHidden = true
        case .denied:
            mark.image = NSImage(
                systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "denied")
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
final class ChoiceCard: NSView {
    let id: String
    var onSelect: ((String) -> Void)?

    private let radio: NSButton
    private let statusLabel = NSTextField(labelWithString: "")
    private var linkButton: NSButton?

    var status: String {
        get { statusLabel.stringValue }
        set {
            statusLabel.stringValue = newValue
            statusLabel.isHidden = newValue.isEmpty
        }
    }

    var isEnabled: Bool = true {
        didSet {
            radio.isEnabled = isEnabled
            alphaValue = isEnabled ? 1 : 0.45
        }
    }

    var isSelected: Bool {
        get { radio.state == .on }
        set {
            radio.state = newValue ? .on : .off
            layer?.borderColor = newValue
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            layer?.borderWidth = newValue ? 2 : 1
        }
    }

    init(id: String, title: String, detail: String, accessories: [NSView] = []) {
        self.id = id
        radio = NSButton(radioButtonWithTitle: title, target: nil, action: nil)
        super.init(frame: .zero)

        radio.target = self
        radio.action = #selector(chose)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4
        detailLabel.preferredMaxLayoutWidth = 170

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.isHidden = true

        linkButton = accessories.compactMap { $0 as? NSButton }.last { $0.bezelStyle == .inline }

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView(views: [radio, detailLabel, statusLabel] + accessories)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for accessory in accessories where accessory is NSTextField || accessory is NSSegmentedControl {
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The install link only belongs on a card for something that isn't here.
    func showLink(_ show: Bool) { linkButton?.isHidden = !show }

    @objc private func chose() { onSelect?(id) }
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
