import AppKit

/// The list of recordings, and what is still owed on each of them.
///
/// The program's other windows are about the present — am I recording, what
/// are the settings. This one is about the archive: what has been recorded,
/// what has been done to it, and what a person can do about the gaps. It is
/// also the only place naming can be corrected, which is the part that can't
/// be automated away — a model that isn't sure leaves the label alone on
/// purpose, and this is where somebody who was there fills it in.
@MainActor
final class RecordingsWindow: NSObject {
    struct RetranscriptionEngine {
        let id: String
        let title: String
    }

    static var retranscriptionEngines: [RetranscriptionEngine] { [
        .init(id: "parakeet", title: "Parakeet"),
        .init(id: "whisper", title: "Whisper"),
        .init(id: "gigaam", title: "GigaAM"),
        .init(id: "assemblyai", title: "AssemblyAI"),
        .init(id: "openai", title: "OpenAI"),
        .init(id: "elevenlabs", title: "ElevenLabs"),
    ] }

    var onImportFiles: (([URL]) -> Void)?
    var onCancelImport: (() -> Void)?
    var onChooseImport: (() -> Void)?
    private var root: URL
    private let panel: NSWindow
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let detailTitle = NSTextField(labelWithString: "")
    private let openingLabel = NSTextField(labelWithString: "")
    private let speakersStack = NSStackView()
    private let finishButton = NSButton()
    private let retranscribeButton = NSButton()
    private let openTranscriptButton = NSButton()
    private let copySummaryButton = NSButton()
    private let openFolderButton = NSButton()
    private let deleteButton = NSButton()
    private let importButton = NSButton()
    private let openRootButton = NSButton()
    private let rootPath = NSTextField(labelWithString: "")
    private let detailTabs = NSTabView()
    private let versionSelector = NSPopUpButton()
    private var versions: [TranscriptVersions.Version] = []
    private var versionSession: URL?
    private var versionKey: String?
    private var selectedVersion: TranscriptVersions.Version? {
        let index = versionSelector.indexOfSelectedItem
        return versions.indices.contains(index) ? versions[index] : nil
    }
    private var artifactDirectory: URL? { selectedVersion?.dir ?? selected?.dir }
    private func key(_ version: TranscriptVersions.Version) -> String {
        version.dir.path + (version.isRequest ? "#request" : "#result")
    }
    private let summaryText = NSTextView()
    private let transcriptText = NSTextView()
    private let busyLabel = NSTextField(labelWithString: "")
    private let importStatus = MediaImportStatusView()
    private let retranscriptionMenu = NSMenu()

    private var items: [SessionInventory.Item] = []
    private var selected: SessionInventory.Item? {
        table.selectedRow >= 0 && table.selectedRow < items.count
            ? items[table.selectedRow]
            : nil
    }
    /// Naming and summarizing take a while and talk to the network; the
    /// buttons stay disabled meanwhile so a second click can't start the same
    /// work twice.
    private var working = false

    init(root: URL) {
        self.root = root
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = localised("Recordings", "Записи")
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("amanu.recordings")
        panel.contentMinSize = NSSize(width: 860, height: 560)

        buildTable()
        panel.contentView = buildLayout()
        if panel.frame.origin == .zero { panel.center() }
        // The first list is read here, on the spot: the window is built once,
        // the first time somebody asks for it, and a window that opened empty
        // and filled in a moment later would be a first picture of it that
        // is wrong. Every later look is `reload`, off the main thread.
        show(SessionInventory.scan(root: root))
    }

    func show() {
        if !panel.isVisible {
            Analytics.track(.artifactOpened, [
                .artifact: .text(Analytics.Artifact.recordingsWindow.rawValue),
            ])
        }
        reload()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// The window's own content, and the list inside it, for the suite that
    /// builds this window in both languages and looks for a sentence left
    /// behind in one of them. The list needs its own way in: the table draws
    /// its cells from the data source rather than from views, so a walk of
    /// the window's subviews goes straight past every row in it.
    var view: NSView? { panel.contentView }

    var listLines: [String] {
        table.tableColumns.map(\.title) + items.flatMap { item in
            table.tableColumns.map { Self.cell(item, column: $0.identifier.rawValue) ?? "" }
        }
    }

    // MARK: - building

    private func buildTable() {
        // The identifier is the program's name for a column and stays
        // English; the title is what a person reads.
        let columns: [(String, String, CGFloat)] = [
            ("when", localised("When", "Когда"), 130),
            ("meeting", localised("Meeting", "Встреча"), 250),
            ("transcript", localised("Transcript", "Расшифровка"), 150),
            ("names", localised("Names", "Имена"), 110),
            ("summary", localised("Summary", "Саммари"), 90),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openFolderClicked)
        retranscriptionMenu.delegate = self
        for engine in Self.retranscriptionEngines {
            let item = NSMenuItem(
                title: localised("Re-transcribe with ", "Расшифровать через ") + engine.title,
                action: #selector(retranscribeWithEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.id
            retranscriptionMenu.addItem(item)
        }
        table.menu = retranscriptionMenu

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    private func buildLayout() -> NSView {
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        openingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // What was said in the meeting, which is the one thing in any of
        // amanu's windows that is not amanu's to translate. Named so that the
        // suite looking for English left in a Russian window knows to walk
        // past it rather than report a person's own words as untranslated.
        openingLabel.identifier = NSUserInterfaceItemIdentifier("meeting-words")
        openingLabel.textColor = .secondaryLabelColor
        openingLabel.lineBreakMode = .byTruncatingTail
        openingLabel.maximumNumberOfLines = 1
        // NSTabView derives its minimum width from this pane's fitting size.
        // The excerpt can truncate at any width; its full text must not become
        // the window's minimum width, even during that fitting calculation.
        openingLabel.setContentCompressionResistancePriority(
            .init(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1),
            for: .horizontal)
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = .secondaryLabelColor

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 6

        for (button, title, action) in [
            (importButton, localised("Import…", "Импортировать…"), #selector(chooseImportClicked)),
            (openRootButton, localised("Open recordings folder", "Открыть папку записей"),
             #selector(openRootClicked)),
            (finishButton, localised("Finish processing", "Доделать"), #selector(finishClicked)),
            (retranscribeButton,
             localised("Re-transcribe", "Расшифровать заново"), #selector(retranscribeClicked)),
            (openTranscriptButton,
             localised("Open transcript", "Открыть расшифровку"), #selector(openTranscriptClicked)),
            (copySummaryButton,
             localised("Copy summary", "Скопировать саммари"), #selector(copySummaryClicked)),
            (openFolderButton, localised("Open folder", "Открыть папку"), #selector(openFolderClicked)),
            (deleteButton, localised("Delete", "Удалить"), #selector(deleteClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        importButton.identifier = NSUserInterfaceItemIdentifier("choose-media-import")
        openTranscriptButton.identifier = NSUserInterfaceItemIdentifier("open-transcript")
        copySummaryButton.identifier = NSUserInterfaceItemIdentifier("copy-summary")
        openRootButton.identifier = NSUserInterfaceItemIdentifier("open-recordings-folder")
        rootPath.stringValue = root.path
        rootPath.font = .systemFont(ofSize: 11)
        rootPath.textColor = .secondaryLabelColor
        rootPath.lineBreakMode = .byTruncatingMiddle
        rootPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootPath.toolTip = root.path
        let toolbar = NSStackView(views: [importButton, openRootButton, NSView(), rootPath])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.heightAnchor.constraint(equalTo: importButton.heightAnchor).isActive = true

        let processingButtons = NSStackView(views: [
            finishButton, retranscribeButton, openTranscriptButton,
            copySummaryButton, openFolderButton, deleteButton,
        ])
        processingButtons.orientation = .horizontal
        processingButtons.spacing = 8
        processingButtons.heightAnchor.constraint(equalTo: finishButton.heightAnchor).isActive = true

        let detailScroll = NSScrollView()
        detailScroll.documentView = speakersStack
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        speakersStack.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        NSLayoutConstraint.activate([
            speakersStack.leadingAnchor.constraint(
                equalTo: detailScroll.contentView.leadingAnchor, constant: 4),
            speakersStack.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            speakersStack.trailingAnchor.constraint(
                equalTo: detailScroll.contentView.trailingAnchor, constant: -8),
        ])

        let speakersContent = NSStackView(views: [openingLabel, detailScroll])
        speakersContent.orientation = .vertical
        speakersContent.distribution = .fill
        speakersContent.alignment = .leading
        speakersContent.spacing = 8
        speakersContent.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
            openingLabel.widthAnchor.constraint(equalTo: speakersContent.widthAnchor, constant: -20),
            detailScroll.widthAnchor.constraint(equalTo: speakersContent.widthAnchor, constant: -20),
        ])
        // NSTabView owns its content view's frame. A stack view calculates
        // its own frame during layout, accumulating the tab's inset on each
        // update if used directly. Keep that layout inside a plain tab view.
        let speakersPane = NSView()
        speakersContent.translatesAutoresizingMaskIntoConstraints = false
        speakersPane.addSubview(speakersContent)
        NSLayoutConstraint.activate([
            speakersContent.leadingAnchor.constraint(equalTo: speakersPane.leadingAnchor),
            speakersContent.trailingAnchor.constraint(equalTo: speakersPane.trailingAnchor),
            speakersContent.topAnchor.constraint(equalTo: speakersPane.topAnchor),
            speakersContent.bottomAnchor.constraint(equalTo: speakersPane.bottomAnchor),
        ])
        for (id, label, view) in [
            ("summary", localised("Summary", "Саммари"), previewScroll(summaryText)),
            ("transcript", localised("Transcript", "Расшифровка"), previewScroll(transcriptText)),
            ("speakers", localised("Speakers", "Участники"), speakersPane),
        ] as [(String, String, NSView)] {
            let tab = NSTabViewItem(identifier: id)
            tab.label = label
            tab.view = view
            detailTabs.addTabViewItem(tab)
        }

        versionSelector.identifier = .init("transcript-versions")
        versionSelector.target = self
        versionSelector.action = #selector(versionSelected(_:))
        versionSelector.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSStackView(views: [detailTitle, versionSelector, detailTabs, processingButtons, busyLabel])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        NSLayoutConstraint.activate([
            detailTitle.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detailTabs.widthAnchor.constraint(equalTo: detail.widthAnchor),
            versionSelector.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        detailTabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = "amanu.recordings.split"
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        importStatus.onCancel = { [weak self] in self?.onCancelImport?() }
        let content = NSStackView(views: [
            toolbar, importStatus, split,
        ])
        content.orientation = .vertical
        content.distribution = .fill
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 6, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = MediaDropView()
        container.onFiles = { [weak self] urls in self?.onImportFiles?(urls) }
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            importStatus.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            split.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])
        return container
    }

    private func previewScroll(_ text: NSTextView) -> NSScrollView {
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    /// Show another recordings folder: the one Setup has just moved amanu to.
    func setRoot(_ folder: URL) {
        root = folder
        rootPath.stringValue = folder.path
        rootPath.toolTip = folder.path
        table.deselectAll(nil)
        reload()
    }

    func updateImport(_ update: MediaImportCoordinator.Update) {
        importStatus.update(update)
    }

    func finishImport(_ result: MediaImportCoordinator.Result) {
        importStatus.finish(result)
        reload()
    }

    // MARK: - data

    /// The scan in flight, if one is, and a count that says which scan is
    /// the latest: an older one finishing late must not overwrite a newer
    /// one's answer.
    private var scan: Task<Void, Never>?
    private var scans = 0

    /// Read the folder again, off the main thread.
    ///
    /// `SessionInventory.scan` reads every session's meta.json and parses its
    /// transcript, and on the main thread that was a window that stopped
    /// answering for as long as the archive took to read — on every opening,
    /// every rename and every delete, and growing with every meeting kept.
    private func reload() {
        scans += 1
        let generation = scans
        let root = self.root
        // Carried across by hand: a detached task does not inherit the home
        // a test scoped, and the scan reads the config for what is owed.
        let home = Home.current
        scan = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Home.$scoped.withValue(home) { SessionInventory.scan(root: root) }
            }.value
            guard let self, generation == self.scans else { return }
            self.show(found)
            self.scan = nil
        }
    }

    /// Wait for the latest scan to be on screen. For tests, which would
    /// otherwise have to guess how long reading a folder takes.
    func settled() async {
        while let scan { await scan.value }
    }

    /// Something changed in the recordings folder that this window did not
    /// do itself — a transcript or a summary finished. Read again if anybody
    /// is looking; a closed window reads when it opens.
    func sessionsChanged() {
        guard panel.isVisible else { return }
        reload()
    }

    private func show(_ found: [SessionInventory.Item]) {
        let previous = selected?.dir
        items = found
        table.reloadData()
        if let previous, let row = items.firstIndex(where: { $0.dir == previous }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        showDetail()
    }

    @objc private func versionSelected(_ sender: NSPopUpButton) {
        versionKey = selectedVersion.map(key)
        showDetail()
    }

    private func showDetail() {
        if versionSession != selected?.dir {
            versionSession = selected?.dir
            versionKey = nil
        }
        versions = selected.map { TranscriptVersions.read($0.dir) } ?? []
        versionSelector.removeAllItems()
        for (index, version) in versions.enumerated() {
            let item = NSMenuItem(title: "\(index + 1) · \(version.title)", action: nil, keyEquivalent: "")
            item.toolTip = "\(version.engine) · \(version.model) · \(version.createdAt)"
            versionSelector.menu?.addItem(item)
        }
        if let index = versions.firstIndex(where: { key($0) == versionKey }) {
            versionSelector.selectItem(at: index)
        } else if let index = versions.lastIndex(where: { !$0.isRequest }) {
            versionSelector.selectItem(at: index)
        }
        versionSelector.isHidden = versions.count < 2
        versionKey = selectedVersion.map(key)

        speakersStack.arrangedSubviews.forEach {
            speakersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let item = selected else {
            detailTitle.stringValue = items.isEmpty
                ? localised("No recordings yet", "Записей пока нет")
                : localised("Select a recording", "Выберите запись")
            openingLabel.stringValue = ""
            summaryText.string = ""
            transcriptText.string = ""
            updateButtons()
            return
        }

        detailTitle.stringValue = item.title ?? item.name
        let dir = artifactDirectory ?? item.dir
        if let request = selectedVersion, request.isRequest {
            summaryText.string = ""
            openingLabel.stringValue = ""
            transcriptText.string = request.title
            if case .failed(let reason) = request.state { transcriptText.string += "\n\n" + reason }
            summaryText.identifier = nil
            transcriptText.identifier = nil
            updateButtons()
            return
        }
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        var summaryPreview = summary ?? (item.summary == .off
            ? localised("Summaries are off.", "Саммари выключены.")
            : localised("No summary yet.", "Саммари пока нет."))
        summaryText.identifier = summary == nil ? nil : .init("meeting-words")
        if summary != nil && !PostProcessor.hasCurrentSummary(dir) {
            summaryPreview = localised(
                "This summary belongs to the previous transcript.\n\n",
                "Это саммари предыдущей расшифровки.\n\n") + summaryPreview
        }
        summaryText.textStorage?.setAttributedString(MarkdownPreview.render(summaryPreview))
        let transcript = PostProcessor.readTranscript(dir)
        let markdown = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let transcriptPreview = markdown ?? transcript?.rendered(
            title: item.title ?? item.name, names: SpeakerNames.read(from: dir))
            ?? localised("No transcript yet.", "Расшифровки пока нет.")
        transcriptText.textStorage?.setAttributedString(MarkdownPreview.render(transcriptPreview))
        transcriptText.identifier = markdown != nil || transcript != nil ? .init("meeting-words") : nil
        for text in [summaryText, transcriptText] { text.scrollToBeginningOfDocument(nil) }
        guard let transcript else {
            openingLabel.stringValue = item.transcript == .pending
                ? localised("Not transcribed yet.", "Ещё не расшифровано.")
                : localised(
                    "No transcript — nothing to name.",
                    "Расшифровки нет — некому давать имена.")
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: dir)
        openingLabel.stringValue = SessionInventory.opening(of: transcript, names: names)
            .replacingOccurrences(of: "\n", with: " · ")
        for sample in SessionInventory.samples(transcript: transcript, names: names) {
            speakersStack.addArrangedSubview(speakerRow(sample, in: dir))
        }
        updateButtons()
    }

    /// One speaker: what they said, and a field for who they are.
    ///
    /// Both samples are shown because they answer different questions — the
    /// first line is where somebody gets greeted by name, and the longest turn
    /// is what identifies a person by what they were talking about when nobody
    /// said any names at all.
    private func speakerRow(_ sample: SessionInventory.Sample, in dir: URL) -> NSView {
        let label = NSTextField(labelWithString: SpeakerNames.described(label: sample.label))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let field = NSTextField(string: sample.name ?? "")
        field.placeholderString = localised("name", "имя")
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        field.target = self
        field.action = #selector(nameEdited(_:))
        field.identifier = .init("\(dir.path)\n\(sample.label)")

        let turns = localised("\(sample.turns) turns", "реплик: \(sample.turns)")
        let provenance = NSTextField(labelWithString: sample.source.map {
            "\($0.described) · " + turns
        } ?? turns)
        provenance.font = .systemFont(ofSize: 10)
        provenance.textColor = .tertiaryLabelColor

        let head = NSStackView(views: [label, field, provenance])
        head.orientation = .horizontal
        head.spacing = 8

        let quotes = NSTextField(wrappingLabelWithString: [
            sample.first.isEmpty
                ? nil : localised("first: ", "первая: ") + sample.first,
            sample.longest == sample.first || sample.longest.isEmpty
                ? nil : localised("longest: ", "самая длинная: ") + sample.longest,
        ].compactMap { $0 }.joined(separator: "\n"))
        quotes.font = .systemFont(ofSize: 11)
        quotes.textColor = .secondaryLabelColor
        quotes.lineBreakMode = .byTruncatingTail
        quotes.maximumNumberOfLines = 4
        quotes.preferredMaxLayoutWidth = 640

        let row = NSStackView(views: [head, quotes])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func updateButtons() {
        let item = selected
        finishButton.isEnabled = !working && (selectedVersion?.isRequest == true
            ? item?.transcript.isOutstanding ?? false
            : artifactDirectory.map { !PostProcessor.outstanding($0).isEmpty } ?? item?.isOutstanding ?? false)
        retranscribeButton.isEnabled = !working && (item?.hasAudio ?? false)
        openTranscriptButton.isEnabled = selectedVersion?.isRequest != true && (artifactDirectory.map {
            PostProcessor.readTranscript($0) != nil || FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("transcript.md").path)
        } ?? false)
        copySummaryButton.isEnabled = selectedVersion?.isRequest != true
            && artifactDirectory.flatMap(Self.summary(in:)) != nil
        openFolderButton.isEnabled = item != nil
        deleteButton.isEnabled = !working && item != nil
        busyLabel.isHidden = !working
        busyLabel.stringValue = working ? localised("working…", "работаю…") : ""
    }

    /// The row-level action belongs only beside a failed transcript whose
    /// source audio still exists. A generic action column would put buttons
    /// beside healthy rows and make the failure harder, not easier, to act on.
    static func inlineRetranscribeTitle(for item: SessionInventory.Item) -> String? {
        guard case .failed = item.transcript, item.hasAudio else { return nil }
        return localised("Re-transcribe", "Расшифровать заново")
    }

    // MARK: - actions

    @objc private func nameEdited(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.components(separatedBy: "\n")
        guard parts.count == 2 else { return }
        PostProcessor.rename(parts[1], to: sender.stringValue, in: URL(fileURLWithPath: parts[0]))
        reload()
    }

    /// What Finish processing does about one recording.
    enum Decision: Equatable {
        /// A transcript exists and something after it is still owed.
        case finish
        /// No transcript, but audio to make one from.
        case transcribe(clearingFirst: Bool)
        /// Nothing can be done, and this is the sentence that says why.
        case refuse(String)
        /// Everything that could be done has been.
        case nothingOwed
    }

    /// Which of those it is, decided before anything is run or shown.
    ///
    /// Through `PostProcessor.plan` rather than around it: a button that
    /// reached its own conclusion about a folder is the bug this replaces —
    /// for a settled recording with no transcript this one used to run the
    /// post-processing that needs one, get nothing back, and say nothing
    /// about it. What is left here is the part the window owns, which is
    /// which of the plans it can carry out and in whose language it answers.
    /// A function of its own because `runModal` blocks, and because a
    /// sentence nothing can call is a sentence nothing can check.
    static func decision(
        for item: SessionInventory.Item,
        policy: PostProcessor.Policy = .configured,
        transcriptionEnabled: Bool = Config.transcriptionEnabled()
    ) -> Decision {
        switch PostProcessor.plan(for: item, transcriptionEnabled: transcriptionEnabled) {
        case .refuse(let why):
            return .refuse(why.described)
        case .transcribe(let clearingFirst):
            return .transcribe(clearingFirst: clearingFirst)
        case .finish:
            return PostProcessor.outstanding(item.dir, policy: policy).isEmpty
                ? .nothingOwed
                : .finish
        }
    }

    /// Said when the button was pressed and there was nothing to press it
    /// for. A property of its own because two places say it — the decision
    /// made before the work, and the work coming back empty afterwards — and
    /// they must say the same thing.
    static var nothingOwedLine: String {
        localised(
            "Everything that can be done here is already done.",
            "Всё, что можно было сделать, уже сделано.")
    }

    @objc private func finishClicked() {
        guard let item = selected else { return }
        if let version = selectedVersion, !version.isRequest, version.dir != item.dir {
            working = true
            updateButtons()
            Task {
                await PostProcessor.finish(version.dir)
                working = false
                reload()
            }
            return
        }
        switch Self.decision(for: item) {
        case .refuse(let why):
            say(why, about: item)

        case .nothingOwed:
            say(Self.nothingOwedLine, about: item)

        // Asked without a confirmation, unlike Re-transcribe: there is no
        // transcript here for the work to throw away.
        case .transcribe(let clearingFirst):
            if clearingFirst, let why = Self.retranscriptionRefusal(for: item.dir) {
                say(why, about: item)
                return
            }
            if clearingFirst { PostProcessor.markForRetranscription(item.dir) }
            onRetranscribe?(item.dir)
            reload()

        case .finish:
            working = true
            updateButtons()
            Task {
                let work = await PostProcessor.finish(item.dir)
                working = false
                reload()
                if work.isEmpty { say(Self.nothingDoneLine(for: item.dir), about: item) }
            }
        }
    }

    /// What to say when Finish processing came back having done nothing.
    ///
    /// Not always good news, which is how it used to read: the work also
    /// comes back empty when another amanu — or this one's own queue — has
    /// the session, and when the config file broke after the button was
    /// offered. Only once both are ruled out does it mean what it says, or
    /// that the transcript could not be read, which the log has.
    static func nothingDoneLine(for dir: URL) -> String {
        if let reason = Config.unreadableReason {
            return PostProcessor.Refusal.configUnreadable(reason).described
        }
        if let holder = SessionClaim.holder(dir), holder.isAlive {
            return SessionClaim.Busy(session: dir.lastPathComponent, holder: holder).described
        }
        return nothingOwedLine
    }

    /// Why a recording cannot be cleared for re-transcription right now, or
    /// nil when it can. Asked before anything is written: the engine choice
    /// used to be stored first and the clearing then refused in silence, so
    /// the recording kept its transcript, gained an engine nobody saw take
    /// effect, and the window said nothing.
    static func retranscriptionRefusal(for dir: URL) -> String? {
        if let reason = Config.unreadableReason {
            return PostProcessor.Refusal.configUnreadable(reason).described
        }
        guard SessionClaim.isHeld(dir) else { return nil }
        return SessionClaim.Busy(session: dir.lastPathComponent, holder: SessionClaim.holder(dir))
            .described
    }

    /// An answer with nothing to decide: the recording it is about, and one
    /// sentence saying what happened to it.
    private func say(_ sentence: String, about item: SessionInventory.Item) {
        let alert = NSAlert()
        alert.messageText = item.title ?? item.name
        alert.informativeText = sentence
        alert.addButton(withTitle: localised("OK", "Ладно"))
        alert.runModal()
    }

    /// Confirm recognition because a cloud engine can incur a charge. Existing
    /// results survive both successful and failed attempts.
    @objc private func retranscribeClicked() {
        confirmRetranscription(engine: nil)
    }

    @objc private func retranscribeWithEngine(_ sender: NSMenuItem) {
        confirmRetranscription(engine: sender.representedObject as? String)
    }

    private func confirmRetranscription(engine: String?) {
        guard let item = selected, item.hasAudio else { return }
        let alert = NSAlert()
        alert.messageText = localised(
            "Transcribe \(item.title ?? item.name) again?",
            "Расшифровать «\(item.title ?? item.name)» заново?")
        alert.informativeText = localised(
            """
            A new transcript is made from the audio. The current transcript, its speaker \
            names and summary remain available as a separate version.
            """,
            """
            Из звука будет сделана новая расшифровка. Нынешняя расшифровка, имена \
            участников и саммари сохранятся отдельным вариантом.
            """)
        alert.addButton(withTitle: localised("Transcribe again", "Расшифровать заново"))
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let why = Self.markForRetranscription(item.dir, engine: engine) {
            say(why, about: item)
            return
        }
        onRetranscribe?(item.dir)
        reload()
    }

    /// Clear a recording for re-transcription with the engine chosen for it,
    /// or say why not. The engine is written only once the clearing is sure
    /// to happen.
    @discardableResult
    static func markForRetranscription(_ dir: URL, engine: String?) -> String? {
        if let why = retranscriptionRefusal(for: dir) { return why }
        let previous = SessionState.value(dir, SessionState.Key.transcriptionEngine)
        if let engine {
            SessionState.update(dir, with: [SessionState.Key.transcriptionEngine: engine])
        }
        guard PostProcessor.markForRetranscription(dir) else {
            // Taken between the question and the clearing: put the choice
            // back as it was, and say so.
            if engine != nil {
                SessionState.update(dir, with: [SessionState.Key.transcriptionEngine: previous])
            }
            return retranscriptionRefusal(for: dir) ?? nothingOwedLine
        }
        return nil
    }

    @objc private func inlineRetranscribeClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        showDetail()
        retranscribeClicked()
    }

    @objc private func chooseImportClicked() { onChooseImport?() }

    @objc private func openRootClicked() {
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.recordingsRoot.rawValue),
        ])
        NSWorkspace.shared.open(root)
    }

    @objc private func openTranscriptClicked() {
        guard selected != nil else { return }
        guard let dir = artifactDirectory, selectedVersion?.isRequest != true,
              let file = Self.readableTranscript(in: dir) else { return }
        Self.openTranscript(file,
            openDefault: { file in
                guard NSWorkspace.shared.urlForApplication(toOpen: file) != nil else { return false }
                return NSWorkspace.shared.open(file)
            },
            openTextEdit: { file in
                guard let textEdit = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.apple.TextEdit"
                ) else {
                    let alert = NSAlert()
                    alert.messageText = localised(
                        "Could not open the transcript", "Не удалось открыть расшифровку")
                    alert.informativeText = file.path
                    alert.runModal()
                    return
                }
                NSWorkspace.shared.open(
                    [file], withApplicationAt: textEdit,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        Task { @MainActor in NSAlert(error: error).runModal() }
                    }
                }
            })
    }

    @objc private func copySummaryClicked() {
        guard selected != nil, selectedVersion?.isRequest != true,
              let dir = artifactDirectory, let summary = Self.summary(in: dir) else { return }
        Self.copy(summary: summary, to: .general)
        // The pasteboard gives no sign of its own, so the button says once
        // that it worked and then goes back to what it does.
        copySummaryButton.title = localised("Copied", "Скопировано")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copySummaryButton.title = localised("Copy summary", "Скопировать саммари")
        }
    }

    /// The summary as written to disk, or nil when there is nothing worth
    /// copying.
    static func summary(in dir: URL) -> String? {
        guard let text = try? String(
            contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Puts the summary on the pasteboard twice: as Markdown for the chat
    /// apps and editors that read it, and as rich text for the ones that
    /// paste formatting, so neither gets a wall of `#` and `-`.
    static func copy(summary: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        // The preview's text colour follows the window's appearance; written
        // into RTF it would paste as white text out of a dark window.
        let rendered = NSMutableAttributedString(attributedString: MarkdownPreview.render(summary))
        rendered.removeAttribute(
            .foregroundColor, range: NSRange(location: 0, length: rendered.length))
        let rtf = try? rendered.data(
            from: NSRange(location: 0, length: rendered.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.declareTypes(rtf == nil ? [.string] : [.string, .rtf], owner: nil)
        pasteboard.setString(summary, forType: .string)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
    }

    static func readableTranscript(in dir: URL) -> URL? {
        let file = dir.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let transcript = PostProcessor.readTranscript(dir) else { return nil }
        do {
            try transcript.writeMarkdown(to: dir, names: SpeakerNames.read(from: dir))
            return file
        } catch {
            return nil
        }
    }

    static func openTranscript(
        _ file: URL,
        openDefault: (URL) -> Bool,
        openTextEdit: (URL) -> Void
    ) {
        if !openDefault(file) { openTextEdit(file) }
    }

    @objc private func openFolderClicked() {
        guard let item = selected else { return }
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.sessionFolder.rawValue),
        ])
        NSWorkspace.shared.open(item.dir)
    }

    /// To the Trash, never `rm`. These are meetings: the cost of a mistaken
    /// delete is somebody's only record of a conversation, and the Trash is
    /// what makes that recoverable.
    @objc private func deleteClicked() {
        guard let item = selected else { return }
        if let why = Self.deleteRefusal(for: item.dir) {
            say(why, about: item)
            return
        }
        let alert = NSAlert()
        alert.messageText = localised(
            "Move \(item.title ?? item.name) to the Trash?",
            "Переместить «\(item.title ?? item.name)» в корзину?")
        alert.informativeText = localised(
            "The recording, its transcript and its summary go together.",
            "Запись, её расшифровка и саммари уйдут вместе.")
        alert.addButton(withTitle: localised("Move to Trash", "В корзину"))
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Asked again: the alert waited for as long as the person did, and a
        // queued transcription may have taken the session meanwhile.
        if let why = Self.deleteRefusal(for: item.dir) {
            say(why, about: item)
            return
        }

        NSWorkspace.shared.recycle([item.dir]) { [weak self] _, error in
            MainActor.assumeIsolated {
                if let error {
                    let failure = NSAlert(error: error)
                    failure.runModal()
                }
                self?.reload()
            }
        }
    }

    /// Why a session cannot go to the Trash now, or nil when it can.
    ///
    /// A session being transcribed or summarised is a folder something is
    /// still writing into. Moved out from under it, the work fails against a
    /// path that is gone, and whatever it was about to write lands nowhere —
    /// or, for a recording-only archive, the audio is half-compressed in the
    /// Trash. The claim file is what says somebody has it, this process or
    /// the command line.
    static func deleteRefusal(for dir: URL) -> String? {
        guard SessionClaim.isHeld(dir) else { return nil }
        return localised(
            "amanu is working on this recording right now — transcribing or summarising it. "
                + "Delete it once that has finished.",
            "amanu сейчас работает с этой записью — расшифровывает её или пишет саммари. "
                + "Удалите её, когда это закончится.")
    }

    /// Called when a session is queued for transcription again, so the daemon
    /// can pick it up without waiting for the next launch.
    var onRetranscribe: ((URL) -> Void)?
}

extension RecordingsWindow: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let enabled = selected?.hasAudio == true && !working
        for item in menu.items { item.isEnabled = enabled }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard row < items.count, let column = tableColumn?.identifier.rawValue else { return nil }
        return Self.cell(items[row], column: column)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < items.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let label = NSTextField(labelWithString: Self.cell(item, column: column) ?? "")
        label.lineBreakMode = .byTruncatingTail

        guard column == "transcript", let title = Self.inlineRetranscribeTitle(for: item) else {
            return label
        }

        let retry = NSButton(
            title: title, target: self, action: #selector(inlineRetranscribeClicked(_:)))
        retry.bezelStyle = .rounded
        retry.controlSize = .mini
        retry.tag = row

        let cell = NSStackView(views: [label, retry])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 6
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retry.setContentCompressionResistancePriority(.required, for: .horizontal)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail()
    }

    /// One cell, as words. Apart from the data source this is what
    /// `listLines` reads, so that the suite and the window cannot disagree
    /// about what a row says.
    static func cell(_ item: SessionInventory.Item, column: String) -> String? {
        switch column {
        case "when":
            return item.started.map { SessionInventory.Item.stamp.string(from: $0) } ?? item.name
        case "meeting":
            let length = item.duration.map {
                localised(" · \(Int($0 / 60))m", " · \(Int($0 / 60)) мин")
            } ?? ""
            return (item.title ?? item.name) + length
        case "transcript":
            return item.transcript.described + (item.engine.map { " (\($0))" } ?? "")
        case "names":
            guard let counts = item.namedSpeakers, counts.total > 0 else {
                return item.speakers.described
            }
            return "\(counts.named)/\(counts.total)"
        case "summary":
            return item.summary.described
        default:
            return nil
        }
    }
}
