import AppKit
import AVFoundation

/// A top-origin document keeps the first participant at the top as the
/// surrounding split view or window changes size.
private final class ParticipantsStack: NSStackView {
    override var isFlipped: Bool { true }
}

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
        .init(id: "compatible", title: localised("Compatible server", "Совместимый сервер")),
    ] }

    var onImportFiles: (([URL]) -> Void)?
    var onCancelImport: (() -> Void)?
    var onChooseImport: (() -> Void)?
    private var root: URL
    private let panel: NSWindow
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let recordingsSplit = NSSplitView()
    private var preReviewListHeight: CGFloat?

    private let detailTitle = NSTextField(labelWithString: "")
    private let participantsStatus = NSTextField(labelWithString: "")
    private let speakersStack = ParticipantsStack()
    private let participantsScroll = NSScrollView()
    private var updatingTable = false
    private var displayedTranscriptID: String?
    private var displayedNames: Data?
    private let finishButton = NSButton()
    private let retranscribeButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let openTranscriptButton = NSButton()
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
    private let busyIndicator = NSProgressIndicator()
    private let importStatus = MediaImportStatusView()
    private let retranscriptionMenu = NSMenu()
    private let reviewNotice = NSTextField(labelWithString: "")
    private let confirmReviewButton = NSButton()
    private let skipReviewButton = NSButton()
    private let updateSummaryButton = NSButton()
    private var reviewDirectories: [URL] = []
    private var activeReviewDirectory: URL?
    private var nameFields: [NSTextField] = []
    private var nameProvenance: [ObjectIdentifier: (NSTextField, Int)] = [:]
    private var flushingSpeakerNames = false
    private var suppressReviewPresentation = false
    private var quitting = false
    private var reviewWork: Task<Void, Never>?
    private var postReviewWork: [UUID: Task<Void, Never>] = [:]
    var confirmLeavingReview: @MainActor (Int) -> Bool = { count in
        let alert = NSAlert()
        alert.messageText = localised("Create the summary with these names?", "Создать саммари с этими именами?")
        alert.informativeText = count > 1
            ? localised("Saved names will be used for \(count) meetings waiting for review.",
                        "Сохранённые имена будут использованы для встреч в очереди: \(count).")
            : localised("Saved names will be kept. You can correct them again later.",
                        "Сохранённые имена останутся. Позже их можно исправить ещё раз.")
        alert.addButton(withTitle: localised("Create summary", "Создать саммари"))
        alert.addButton(withTitle: localised("Continue naming", "Продолжить именование"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private var audioSamples: [String: SpeakerReview.AudioSample] = [:]
    private var audioPlayers: [AVAudioPlayer] = []
    private var audioStop: Timer?
    private weak var playingButton: NSButton?

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
        panel.delegate = self
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
        suppressReviewPresentation = false
        if !panel.isVisible {
            Analytics.track(.artifactOpened, [
                .artifact: .text(Analytics.Artifact.recordingsWindow.rawValue),
            ])
        }
        reload()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Review is offered without taking focus away from the app in use.
    func showSpeakerReview(_ directory: URL) async {
        let directory = directory.standardizedFileURL
        if !reviewDirectories.contains(directory) { reviewDirectories.append(directory) }
        if suppressReviewPresentation {
            skipQueuedReviewsWithoutPresenting()
            return
        }
        if let current = activeReviewDirectory, current != directory, SpeakerReview.isPending(current) {
            reload()
            return
        }
        let target = reviewDirectories.first ?? directory
        activeReviewDirectory = target
        if root.standardizedFileURL != target.deletingLastPathComponent() {
            setRoot(target.deletingLastPathComponent())
        } else { reload() }
        await settled()
        if let row = items.firstIndex(where: { $0.dir.standardizedFileURL == target }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            versionKey = nil
            showDetail()
            detailTabs.selectTabViewItem(withIdentifier: "speakers")
            expandParticipantsForReview()
            panel.orderFront(nil)
        }
    }

    /// Give the review more room without overwriting the person's saved split.
    private func expandParticipantsForReview() {
        guard preReviewListHeight == nil else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = scroll.frame.height
        guard height > 0 else { return }
        preReviewListHeight = height
        recordingsSplit.autosaveName = nil
        if height > 165 { recordingsSplit.setPosition(160, ofDividerAt: 0) }
    }

    private func restoreRecordingsSplit() {
        guard let height = preReviewListHeight else { return }
        recordingsSplit.setPosition(height, ofDividerAt: 0)
        recordingsSplit.autosaveName = "amanu.recordings.split"
        preReviewListHeight = nil
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
        // No stripes: the list is usually a few rows over a tall pane, and the
        // stripes went on down the empty part as a pattern of nothing.
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openFolderClicked)
        retranscriptionMenu.delegate = self
        // `menuWillOpen` decides what is enabled; validation would undo it.
        retranscriptionMenu.autoenablesItems = false
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
        // Text in the detail half may truncate at any width, and none of it may
        // become the window's minimum width: NSTabView and the window both
        // derive a minimum from the fitting size, which only holds views
        // whose resistance is above `fittingSizeCompression`.
        let truncatable = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.maximumNumberOfLines = 1
        detailTitle.setContentCompressionResistancePriority(truncatable, for: .horizontal)
        participantsStatus.font = .systemFont(ofSize: 12)
        participantsStatus.textColor = .secondaryLabelColor
        participantsStatus.lineBreakMode = .byTruncatingTail
        participantsStatus.maximumNumberOfLines = 1
        participantsStatus.setContentCompressionResistancePriority(truncatable, for: .horizontal)
        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false
        busyIndicator.isHidden = true
        busyIndicator.setAccessibilityLabel(localised("Working", "Идёт обработка"))

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 6

        for (button, title, action) in [
            (importButton, localised("Import…", "Импортировать…"), #selector(chooseImportClicked)),
            (openRootButton, localised("Open recordings folder", "Открыть папку записей"),
             #selector(openRootClicked)),
            (finishButton, localised("Finish processing", "Завершить обработку"), #selector(finishClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        // Opening and deleting act on the files rather than on the meeting,
        // and are reached for less often than the processing beside them, so
        // they are icons with their names in the tooltip and for VoiceOver:
        // three more Russian titles would leave the meeting's own name no
        // room at the window's minimum width.
        for (button, title, symbol, action) in [
            (openTranscriptButton, localised("Open transcript", "Открыть расшифровку"),
             "doc.text", #selector(openTranscriptClicked)),
            (openFolderButton, localised("Show in Finder", "Показать в Finder"),
             "folder", #selector(openFolderClicked)),
            (deleteButton, localised("Move to Trash", "Переместить в корзину"),
             "trash", #selector(deleteClicked)),
        ] as [(NSButton, String, String, Selector)] {
            button.title = title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.target = self
            button.action = action
        }
        // The choice of engine was only ever in the list's context menu, which
        // nothing on screen points to. The first item of a pull-down is its
        // title rather than a choice; the context menu stays as it was.
        retranscribeButton.identifier = .init("retranscribe")
        retranscribeButton.addItem(withTitle: localised("Re-transcribe", "Расшифровать заново"))
        let configuredEngine = NSMenuItem(
            title: localised("As in Settings", "Как в настройках"),
            action: #selector(retranscribeClicked), keyEquivalent: "")
        configuredEngine.target = self
        retranscribeButton.menu?.addItem(configuredEngine)
        retranscribeButton.menu?.addItem(.separator())
        for engine in Self.retranscriptionEngines {
            let item = NSMenuItem(
                title: engine.title, action: #selector(retranscribeWithEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.id
            retranscribeButton.menu?.addItem(item)
        }
        importButton.identifier = NSUserInterfaceItemIdentifier("choose-media-import")
        openTranscriptButton.identifier = NSUserInterfaceItemIdentifier("open-transcript")
        openRootButton.identifier = NSUserInterfaceItemIdentifier("open-recordings-folder")
        finishButton.identifier = NSUserInterfaceItemIdentifier("finish-processing")
        rootPath.stringValue = root.path
        rootPath.font = .systemFont(ofSize: 11)
        rootPath.textColor = .secondaryLabelColor
        rootPath.lineBreakMode = .byTruncatingMiddle
        // Below the fitting priority, like the detail half's text: at
        // `.defaultLow` the whole path, which is as long as wherever the
        // folder happens to be, was the window's minimum width — beside the
        // Russian buttons a temporary folder's path alone pushed it past 860.
        rootPath.setContentCompressionResistancePriority(truncatable, for: .horizontal)
        rootPath.toolTip = root.path
        let toolbar = NSStackView(views: [importButton, openRootButton, NSView(), rootPath])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.heightAnchor.constraint(equalTo: importButton.heightAnchor).isActive = true

        let detailScroll = participantsScroll
        detailScroll.identifier = .init("participants-scroll")
        detailScroll.documentView = speakersStack
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.hasHorizontalScroller = false
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

        reviewNotice.font = .systemFont(ofSize: 12)
        reviewNotice.textColor = .secondaryLabelColor
        reviewNotice.identifier = .init("speaker-review-notice")
        reviewNotice.lineBreakMode = .byTruncatingTail
        reviewNotice.maximumNumberOfLines = 1
        reviewNotice.setContentCompressionResistancePriority(truncatable, for: .horizontal)
        // Skip and Create summary end a review the same way — both keep the
        // names already entered and go on to the summary — and Skip is there
        // so that leaving names unfilled is visibly allowed rather than
        // something a person has to guess at.
        for (button, title, action, id) in [
            (skipReviewButton, localised("Skip", "Пропустить"),
             #selector(skipReviewClicked), "skip-speaker-review"),
            (confirmReviewButton, localised("Create summary", "Создать саммари"),
             #selector(confirmReviewClicked), "confirm-speaker-review"),
            (updateSummaryButton, localised("Update summary", "Обновить саммари"),
             #selector(updateSummaryClicked), "update-summary"),
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.identifier = .init(id)
        }
        // Accent rather than the default button: none of these has a key
        // equivalent, because Return in a name field has to commit that
        // name, not end the review behind it.
        for button in [confirmReviewButton, updateSummaryButton] {
            button.bezelColor = .controlAccentColor
        }
        let speakersContent = NSStackView(views: [participantsStatus, detailScroll])
        speakersContent.orientation = .vertical
        speakersContent.distribution = .fill
        speakersContent.alignment = .leading
        speakersContent.spacing = 8
        speakersContent.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        NSLayoutConstraint.activate([
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
            ("speakers", localised("Participants", "Участники"), speakersPane),
        ] as [(String, String, NSView)] {
            let tab = NSTabViewItem(identifier: id)
            tab.label = label
            tab.view = view
            detailTabs.addTabViewItem(tab)
        }

        versionSelector.identifier = .init("transcript-versions")
        versionSelector.target = self
        versionSelector.action = #selector(versionSelected(_:))
        versionSelector.controlSize = .small
        versionSelector.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionSelector.setContentCompressionResistancePriority(truncatable, for: .horizontal)

        // The recording's name, and what can be done about it, in one line
        // above the tabs. The actions used to sit in a row under the tabs,
        // as far from the selection as the window allowed, and a review's
        // decision lived inside the Participants tab, so it vanished the
        // moment somebody looked at the transcript to check a voice.
        let titleColumn = NSStackView(views: [detailTitle, reviewNotice, versionSelector])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 4
        titleColumn.detachesHiddenViews = true
        let actions = NSStackView(views: [
            busyIndicator, skipReviewButton, confirmReviewButton, updateSummaryButton, finishButton,
            retranscribeButton, openTranscriptButton, openFolderButton, deleteButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        // The buttons that come and go must give their width back when they
        // go, or the review's two would crowd the meeting's name off the row
        // for every recording that is not in review.
        actions.detachesHiddenViews = true
        // The review's decision, processing, the files, and last the one that
        // cannot be taken back.
        actions.setCustomSpacing(16, after: confirmReviewButton)
        actions.setCustomSpacing(16, after: retranscribeButton)
        actions.setCustomSpacing(16, after: openFolderButton)
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16
        header.setViews([titleColumn], in: .leading)
        header.setViews([actions], in: .trailing)

        let detail = NSStackView(views: [header, detailTabs])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.alignment = .leading
        detail.spacing = 12
        // The bottom margin lives here rather than on the window's content so
        // the split itself still reaches the bottom edge.
        detail.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 8, right: 0)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detailTabs.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        detailTabs.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let split = recordingsSplit
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
    private func reload(preservingParticipants: Bool = false) {
        scans += 1
        let generation = scans
        let root = self.root
        let selectedDirectory = selected?.dir
        let selectedVersionKey = versionKey
        // Carried across by hand: a detached task does not inherit the home
        // a test scoped, and the scan reads the config for what is owed.
        let home = Home.current
        scan = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                Home.$scoped.withValue(home) { SessionInventory.scan(root: root) }
            }.value
            guard let self, generation == self.scans else { return }
            let preserve = preservingParticipants && self.selected?.dir == selectedDirectory
                && self.versionKey == selectedVersionKey
            self.show(found, preservingParticipants: preserve)
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
        reload(preservingParticipants: true)
    }

    private func show(_ found: [SessionInventory.Item], preservingParticipants: Bool = false) {
        let previous = selected?.dir
        items = found
        updatingTable = true
        table.reloadData()
        if let previous, let row = items.firstIndex(where: { $0.dir == previous }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updatingTable = false
        if preservingParticipants, let item = selected, previous == item.dir,
           let dir = artifactDirectory, displayedTranscriptID != nil,
           SpeakerReview.transcriptID(dir) == displayedTranscriptID,
           (try? Data(contentsOf: dir.appendingPathComponent(SpeakerNames.file))) == displayedNames {
            refreshPreviews(in: dir, item: item)
            updateButtons()
        } else {
            showDetail()
        }
    }

    @objc private func versionSelected(_ sender: NSPopUpButton) {
        if let directory = selected?.dir, SpeakerReview.isPending(directory),
           selectedVersion?.dir != directory {
            let wanted = selectedVersion.map(key)
            if let previous = versions.firstIndex(where: { key($0) == versionKey }) {
                versionSelector.selectItem(at: previous)
            }
            guard !working, confirmLeavingReview(1) else { return }
            completeSpeakerReview(version: wanted)
            return
        }
        versionKey = selectedVersion.map(key)
        showDetail()
    }

    private func showDetail() {
        stopAudioSample()
        audioSamples.removeAll()
        nameFields.removeAll()
        nameProvenance.removeAll()
        displayedTranscriptID = nil
        displayedNames = nil
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
            // The title already says it; the pane under it says nothing more.
            detailTitle.stringValue = items.isEmpty
                ? localised("No recordings yet", "Записей пока нет")
                : localised("Select a recording", "Выберите запись")
            detailTitle.toolTip = nil
            participantsStatus.stringValue = ""
            participantsStatus.isHidden = true
            participantsScroll.isHidden = true
            summaryText.string = ""
            transcriptText.string = ""
            updateButtons()
            return
        }

        detailTitle.stringValue = item.title ?? item.name
        detailTitle.toolTip = detailTitle.stringValue
        let dir = artifactDirectory ?? item.dir
        if let request = selectedVersion, request.isRequest {
            summaryText.string = ""
            participantsStatus.stringValue = localised("Transcription is not ready yet.",
                                                       "Расшифровка ещё не готова.")
            participantsStatus.isHidden = false
            participantsScroll.isHidden = true
            transcriptText.string = request.title
            if case .failed(let reason) = request.state { transcriptText.string += "\n\n" + reason }
            summaryText.identifier = nil
            transcriptText.identifier = nil
            updateButtons()
            return
        }
        refreshPreviews(in: dir, item: item)
        let transcript = PostProcessor.readTranscript(dir)
        guard let transcript else {
            participantsStatus.stringValue = item.transcript == .pending
                ? localised("Not transcribed yet.", "Ещё не расшифровано.")
                : localised("No transcript.", "Расшифровки нет.")
            participantsStatus.isHidden = false
            participantsScroll.isHidden = true
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: dir)
        displayedTranscriptID = SpeakerReview.transcriptID(dir)
        displayedNames = try? Data(contentsOf: dir.appendingPathComponent(SpeakerNames.file))
        let samples = SessionInventory.samples(transcript: transcript, names: names)
        // No heading over the list: the tab above it already says
        // Participants, and the list's own rows are the count.
        participantsStatus.stringValue = localised("No participants found.", "Участники не найдены.")
        participantsStatus.isHidden = !samples.isEmpty
        participantsScroll.isHidden = samples.isEmpty
        for (index, sample) in samples.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                speakersStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
            }
            let row = speakerRow(sample, in: dir, audioSession: item.dir,
                                 title: transcript.displaySpeaker(label: sample.label, names: nil))
            speakersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: speakersStack.widthAnchor).isActive = true
        }
        updateButtons()
    }

    private func refreshPreviews(in dir: URL, item: SessionInventory.Item) {
        let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
        var summaryPreview = summary ?? (item.summary == .off
            ? localised("Summaries are off.", "Саммари выключены.")
            : localised("No summary yet.", "Саммари пока нет."))
        summaryText.identifier = summary == nil ? nil : .init("meeting-words")
        if summary != nil && !PostProcessor.hasCurrentSummary(dir) {
            summaryPreview = (PostProcessor.summaryNeedsManualUpdate(dir)
                // A fact rather than an instruction: the Update summary
                // button beside the title is the instruction.
                ? localised("Names have changed since this summary was made.\n\n",
                            "Имена изменились после создания этого саммари.\n\n")
                : localised("This summary belongs to the previous transcript.\n\n",
                            "Это саммари предыдущей расшифровки.\n\n")) + summaryPreview
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
    }

    /// One speaker: what they said, and a field for who they are.
    ///
    /// Both samples are shown because they answer different questions — the
    /// first line is where somebody gets greeted by name, and the longest turn
    /// is what identifies a person by what they were talking about when nobody
    /// said any names at all.
    private func speakerRow(_ sample: SessionInventory.Sample, in dir: URL, audioSession: URL, title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: 145).isActive = true
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = title

        let field = NSTextField(string: sample.name ?? "")
        field.placeholderString = localised("Name", "Имя")
        field.setAccessibilityLabel(localised("Name for \(title)", "Имя: \(title)"))
        // A name's width rather than the pane's: stretched across a wide
        // window, the field read as a place for a paragraph and pushed where
        // the name came from out to the far edge.
        let nameWidth = field.widthAnchor.constraint(equalToConstant: 260)
        nameWidth.priority = .init(700)
        NSLayoutConstraint.activate([
            nameWidth,
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        field.target = self
        field.action = #selector(nameEdited(_:))
        field.delegate = self
        field.identifier = .init("\(dir.path)\n\(sample.label)")
        nameFields.append(field)

        let turns = turnCountLabel(sample.turns)
        let provenance = NSTextField(labelWithString: sample.source.map {
            "\($0.described) · " + turns
        } ?? turns)
        provenance.font = .systemFont(ofSize: 11)
        provenance.textColor = .secondaryLabelColor
        provenance.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameProvenance[ObjectIdentifier(field)] = (provenance, sample.turns)

        let head = NSStackView(views: [label, field, provenance])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        let row = NSStackView(views: [head])
        row.orientation = .vertical
        row.alignment = .leading
        row.identifier = .init("participant-row")
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 4, bottom: 12, right: 8)
        head.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -12).isActive = true

        let audio = SpeakerReview.audioSamples(for: sample, in: audioSession)
        // The captions are the titles `SpeakerReview.audioSamples` gives its
        // clips, which is how a quote finds the clip that plays it.
        let examples = [
            (sample.first, localised("First turn", "Первая реплика"), sample.firstStartMs),
            (sample.longest, localised("Longest turn", "Самая длинная реплика"), sample.longestStartMs),
        ]
        for (index, example) in examples.enumerated() {
            let (text, caption, start) = example
            guard !text.isEmpty, index == 0 || text != sample.first else { continue }
            let time = start.map { milliseconds -> String in
                let seconds = max(0, milliseconds / 1000)
                return String(format: "%d:%02d", seconds / 60, seconds % 60)
            } ?? ""
            let control: NSView
            if let clip = audio.first(where: { $0.title == caption }) {
                let button = NSButton(title: time, target: self, action: #selector(playAudioSample(_:)))
                let id = UUID().uuidString
                audioSamples[id] = clip
                button.identifier = .init("speaker-audio-\(id)")
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
                button.imagePosition = .imageLeading
                button.setAccessibilityLabel(localised("\(title): play \(caption)", "\(title): воспроизвести — \(caption)"))
                button.toolTip = caption
                control = button
            } else {
                // The same moment the button would have played, so the
                // quotes line up whether or not the audio is still there. The
                // caption that used to stand here was cut off by the column.
                let stamp = NSTextField(labelWithString: time)
                stamp.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                stamp.textColor = .tertiaryLabelColor
                stamp.alignment = .center
                stamp.toolTip = caption
                control = stamp
            }
            control.widthAnchor.constraint(equalToConstant: 86).isActive = true
            let quote = NSTextField(wrappingLabelWithString: text)
            quote.identifier = .init("meeting-words")
            quote.font = .systemFont(ofSize: 12)
            quote.textColor = .secondaryLabelColor
            quote.lineBreakMode = .byTruncatingTail
            quote.maximumNumberOfLines = 3
            quote.toolTip = text
            quote.setContentCompressionResistancePriority(.init(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1), for: .horizontal)
            let exampleRow = NSStackView(views: [control, quote])
            exampleRow.orientation = .horizontal
            exampleRow.alignment = .top
            exampleRow.spacing = 10
            row.addArrangedSubview(exampleRow)
            exampleRow.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -12).isActive = true
        }
        if audio.isEmpty {
            let unavailable = NSTextField(labelWithString: localised("Audio unavailable", "Аудио недоступно"))
            unavailable.font = .systemFont(ofSize: 11)
            unavailable.textColor = .secondaryLabelColor
            row.addArrangedSubview(unavailable)
        }
        return row
    }

    private func updateButtons() {
        let item = selected
        let request = selectedVersion?.isRequest == true
        let review = artifactDirectory == item?.dir && item.map { SpeakerReview.isPending($0.dir) } == true
        reviewNotice.isHidden = !review
        // Short enough to stand beside the review's buttons at the minimum
        // width; the rest of what there is to say is in the tooltip.
        reviewNotice.stringValue = review ? localised(
            "Check the names before the summary", "Проверьте имена перед саммари") : ""
        reviewNotice.toolTip = review ? localised(
            "Names are saved as you edit them. Skip keeps the names already entered.",
            "Имена сохраняются при правке. «Пропустить» оставит уже введённые имена.") : nil
        confirmReviewButton.isHidden = !review
        confirmReviewButton.isEnabled = !working
        skipReviewButton.isHidden = !review
        skipReviewButton.isEnabled = !working
        // The contextual actions appear when there is something for them to
        // do, rather than sitting greyed out beside every finished meeting.
        // While a review is open its own buttons are the way forward, and
        // these two would only race it for the same session.
        updateSummaryButton.isHidden = review || request
            || (artifactDirectory.map { !PostProcessor.summaryNeedsManualUpdate($0) } ?? true)
        updateSummaryButton.isEnabled = !working
        let owed = request
            ? item?.transcript.isOutstanding ?? false
            : artifactDirectory.map { !PostProcessor.outstanding($0).isEmpty } ?? item?.isOutstanding ?? false
        finishButton.isHidden = review || !owed
        finishButton.isEnabled = !working
        retranscribeButton.isEnabled = !working && (item?.hasAudio ?? false)
        retranscribeButton.toolTip = item.map { $0.hasAudio } == false
            ? localised("This recording's audio is no longer available.",
                        "Звука этой записи больше нет.")
            : nil
        openTranscriptButton.isEnabled = !request && (artifactDirectory.map {
            PostProcessor.readTranscript($0) != nil || FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("transcript.md").path)
        } ?? false)
        openFolderButton.isEnabled = item != nil
        deleteButton.isEnabled = !working && item != nil
        busyIndicator.isHidden = !working
        if working { busyIndicator.startAnimation(nil) } else { busyIndicator.stopAnimation(nil) }
    }

    @objc private func playAudioSample(_ sender: NSButton) {
        let prefix = "speaker-audio-"
        guard let identifier = sender.identifier?.rawValue, identifier.hasPrefix(prefix),
              let sample = audioSamples[String(identifier.dropFirst(prefix.count))] else { return }
        let wasPlaying = playingButton === sender && audioPlayers.contains(where: \.isPlaying)
        stopAudioSample()
        guard !wasPlaying else { return }
        do {
            let players = try sample.sources.compactMap { source -> (AVAudioPlayer, TimeInterval)? in
                let player = try AVAudioPlayer(contentsOf: source.file)
                guard source.start < player.duration else { return nil }
                player.currentTime = source.start
                guard player.prepareToPlay() else { throw CocoaError(.fileReadUnknown) }
                return (player, source.delay)
            }
            guard let clock = players.first?.0.deviceCurrentTime else { return }
            audioPlayers = players.map(\.0)
            playingButton = sender
            sender.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            // The same audio-device clock aligns separate original tracks;
            // a late track starts after its recorded offset on the clip clock.
            let lead: TimeInterval = 0.1
            for (player, delay) in players {
                guard player.play(atTime: clock + lead + delay) else { throw CocoaError(.fileReadUnknown) }
            }
            let timer = Timer(timeInterval: sample.duration + lead, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopAudioSample() }
            }
            // Menus and window dragging switch run-loop modes; the sample's
            // eight-second boundary still applies while they are open.
            audioStop = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            stopAudioSample()
            if let item = selected { say(error.localizedDescription, about: item) }
        }
    }

    private func stopAudioSample() {
        audioStop?.invalidate()
        audioStop = nil
        audioPlayers.forEach { $0.stop() }
        audioPlayers.removeAll()
        playingButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playingButton = nil
    }

    @objc private func confirmReviewClicked() { completeSpeakerReview() }
    @objc private func skipReviewClicked() { completeSpeakerReview() }

    func completeSpeakerReview(selecting nextSelection: URL? = nil, version nextVersion: String? = nil) {
        guard !working, let item = selected, SpeakerReview.isPending(item.dir) else { return }
        flushSpeakerNames()
        stopAudioSample()
        working = true
        updateButtons()
        reviewWork = Task { [weak self] in
            guard let self else { return }
            defer { reviewWork = nil }
            do {
                try await Self.finishReview(item.dir)
                reviewDirectories.removeAll { $0.standardizedFileURL == item.dir.standardizedFileURL }
                if reviewDirectories.isEmpty { restoreRecordingsSplit() }
                if activeReviewDirectory == item.dir.standardizedFileURL { activeReviewDirectory = nil }
                working = false
                reload()
                continueAfterReview(item.dir)
                if let nextVersion {
                    await settled()
                    versionKey = nextVersion
                    showDetail()
                } else if let nextSelection {
                    await settled()
                    if let row = items.firstIndex(where: { $0.dir == nextSelection }) {
                        table.selectRowIndexes([row], byExtendingSelection: false)
                        if SpeakerReview.isPending(nextSelection) {
                            activeReviewDirectory = nextSelection.standardizedFileURL
                            detailTabs.selectTabViewItem(withIdentifier: "speakers")
                        }
                    }
                } else if let next = reviewDirectories.first { await showSpeakerReview(next) }
            } catch {
                working = false
                updateButtons()
                say(error.localizedDescription, about: item)
            }
        }
    }

    func waitForReviewWork() async { await reviewWork?.value }

    func waitForPostReviewWork() async {
        while let task = postReviewWork.values.first { await task.value }
    }

    private static func finishReview(_ directory: URL) async throws {
        let home = Home.current
        try await Task.detached(priority: .utility) {
            try Home.$scoped.withValue(home) { try SpeakerReview.complete(directory) }
        }.value
    }

    private func continueAfterReview(_ directory: URL) {
        let id = UUID()
        postReviewWork[id] = Task { [weak self] in
            defer { self?.postReviewWork[id] = nil }
            await PostProcessor.finish(directory)
            StopHook.fireIfOwed(directory)
            self?.reload()
        }
    }

    /// Quit waits only for durable decisions and audio settlement. The summary
    /// remains owed if the process exits before its background task finishes.
    func reviewBeforeTermination() async -> Bool {
        if let reviewWork { await reviewWork.value }
        guard reviewDirectories.isEmpty || confirmLeavingReview(reviewDirectories.count) else { return false }
        quitting = true
        suppressReviewPresentation = true
        stopAudioSample()
        return await completeQueuedReviews()
    }

    private func completeQueuedReviews() async -> Bool {
        flushSpeakerNames()
        working = true
        updateButtons()
        defer { working = false; reload() }
        do {
            while let directory = reviewDirectories.first {
                try await Self.finishReview(directory)
                reviewDirectories.removeAll { $0 == directory }
                if activeReviewDirectory == directory { activeReviewDirectory = nil }
                continueAfterReview(directory)
            }
            restoreRecordingsSplit()
            return true
        } catch {
            quitting = false
            suppressReviewPresentation = false
            panel.orderFront(nil)
            if let item = selected { say(error.localizedDescription, about: item) }
            return false
        }
    }

    private func skipQueuedReviewsWithoutPresenting() {
        guard reviewWork == nil else { return }
        reviewWork = Task { [weak self] in
            guard let self else { return }
            _ = await completeQueuedReviews()
            reviewWork = nil
            if !quitting { suppressReviewPresentation = false }
        }
    }

    @objc private func updateSummaryClicked() {
        guard !working, let item = selected, let directory = artifactDirectory,
              !SpeakerReview.isPending(item.dir) else { return }
        flushSpeakerNames()
        do { try PostProcessor.requestSummaryUpdate(directory) }
        catch { say(error.localizedDescription, about: item); return }
        working = true
        updateButtons()
        Task { [weak self] in
            await PostProcessor.finish(directory)
            guard let self else { return }
            working = false
            reload()
        }
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
        if persistName(sender), !flushingSpeakerNames { reload(preservingParticipants: true) }
    }

    private func flushSpeakerNames() {
        flushingSpeakerNames = true
        defer { flushingSpeakerNames = false }
        let fields = nameFields
        panel.makeFirstResponder(nil)
        for field in fields { _ = persistName(field) }
    }

    @discardableResult
    private func persistName(_ sender: NSTextField) -> Bool {
        guard let id = sender.identifier?.rawValue else { return false }
        let parts = id.components(separatedBy: "\n")
        guard parts.count == 2 else { return false }
        let directory = URL(fileURLWithPath: parts[0])
        let entered = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entered != (SpeakerNames.read(from: directory)?.speakers[parts[1]]?.name ?? "") else { return false }
        PostProcessor.rename(parts[1], to: entered, in: directory)
        displayedNames = try? Data(contentsOf: directory.appendingPathComponent(SpeakerNames.file))
        if let (provenance, turns) = nameProvenance[ObjectIdentifier(sender)] {
            provenance.stringValue = SpeakerNames.Source.manual.described + " · "
                + turnCountLabel(turns)
        }
        return true
    }

    private func turnCountLabel(_ count: Int) -> String {
        localised(count == 1 ? "1 turn" : "\(count) turns", "реплик: \(count)")
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

extension RecordingsWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if !quitting { suppressReviewPresentation = false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopAudioSample()
        guard !reviewDirectories.isEmpty else {
            suppressReviewPresentation = true
            return true
        }
        guard !working else { return false }
        guard confirmLeavingReview(reviewDirectories.count) else { return false }
        suppressReviewPresentation = true
        panel.orderOut(nil)
        skipQueuedReviewsWithoutPresenting()
        return false
    }
}

extension RecordingsWindow: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        nameEdited(field)
    }
}

extension RecordingsWindow: NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if updatingTable { return true }
        guard items.indices.contains(row), row != tableView.selectedRow,
              let item = selected, SpeakerReview.isPending(item.dir) else { return true }
        guard !working, confirmLeavingReview(1) else { return false }
        completeSpeakerReview(selecting: items[row].dir)
        return false
    }
    func menuWillOpen(_ menu: NSMenu) {
        // A right-click lands on the row under the pointer, which need not be
        // the selected one, and the menu's actions read the selection: they
        // used to re-transcribe the selected meeting rather than the one
        // clicked. The selection follows the click, unless leaving the current
        // row needs a review decision, which a menu opening is no place for.
        var target = selected
        let clicked = table.clickedRow
        if items.indices.contains(clicked), clicked != table.selectedRow {
            if let current = selected, SpeakerReview.isPending(current.dir) {
                target = nil
            } else {
                table.selectRowIndexes([clicked], byExtendingSelection: false)
                target = selected
            }
        }
        let enabled = target?.hasAudio == true && !working
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
        label.textColor = Self.recedes(item, column: column) ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if column == "transcript", case .failed(let reason) = item.transcript { label.toolTip = reason }

        var views: [NSView] = [label]
        // An icon rather than a titled mini button: the title took the whole
        // column and cut the state beside it down to its first letter, which
        // was the one thing the row had to say.
        if column == "transcript", let title = Self.inlineRetranscribeTitle(for: item) {
            let retry = NSButton(
                title: title, target: self, action: #selector(inlineRetranscribeClicked(_:)))
            retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            retry.imagePosition = .imageOnly
            retry.isBordered = false
            retry.toolTip = title
            retry.setAccessibilityLabel(title)
            retry.tag = row
            retry.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(retry)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 4
        line.translatesAutoresizingMaskIntoConstraints = false

        // A cell view with its text field named, so that the label takes the
        // selection's colours instead of staying dark on an accent row.
        let cell = NSTableCellView()
        cell.textField = label
        cell.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            line.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            line.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Whether a cell is background rather than news. The date, and a step
    /// that is finished or switched off, recede like the secondary columns
    /// in the Finder, so that in a long list what still needs something —
    /// a queued step, a failure, a meeting with nameless speakers — is what
    /// the eye lands on.
    static func recedes(_ item: SessionInventory.Item, column: String) -> Bool {
        func settled(_ step: SessionInventory.Step) -> Bool { step == .done || step == .off }
        switch column {
        case "when": return true
        case "transcript": return settled(item.transcript)
        case "summary": return settled(item.summary)
        case "names":
            guard let counts = item.namedSpeakers, counts.total > 0 else { return settled(item.speakers) }
            return counts.named == counts.total
        default: return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !updatingTable { showDetail() }
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
