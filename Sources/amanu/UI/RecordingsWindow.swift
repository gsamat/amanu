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
    private let root: URL
    private let panel: NSWindow
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private let detailTitle = NSTextField(labelWithString: "")
    private let openingLabel = NSTextField(wrappingLabelWithString: "")
    private let speakersStack = NSStackView()
    private let finishButton = NSButton()
    private let retranscribeButton = NSButton()
    private let openFolderButton = NSButton()
    private let deleteButton = NSButton()
    private let busyLabel = NSTextField(labelWithString: "")

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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = localised("Recordings", "Записи")
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("amanu.recordings")

        buildTable()
        panel.contentView = buildLayout()
        if panel.frame.origin == .zero { panel.center() }
        reload()
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

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }

    private func buildLayout() -> NSView {
        detailTitle.font = .systemFont(ofSize: 13, weight: .medium)
        openingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // What was said in the meeting, which is the one thing in any of
        // amanu's windows that is not amanu's to translate. Named so that the
        // suite looking for English left in a Russian window knows to walk
        // past it rather than report a person's own words as untranslated.
        openingLabel.identifier = NSUserInterfaceItemIdentifier("meeting-words")
        openingLabel.textColor = .secondaryLabelColor
        openingLabel.lineBreakMode = .byTruncatingTail
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = .secondaryLabelColor

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 6

        for (button, title, action) in [
            (finishButton, localised("Finish processing", "Доделать"), #selector(finishClicked)),
            (retranscribeButton,
             localised("Re-transcribe", "Расшифровать заново"), #selector(retranscribeClicked)),
            (openFolderButton, localised("Open folder", "Открыть папку"), #selector(openFolderClicked)),
            (deleteButton, localised("Delete", "Удалить"), #selector(deleteClicked)),
        ] as [(NSButton, String, Selector)] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }

        let buttons = NSStackView(views: [
            finishButton, retranscribeButton, openFolderButton, deleteButton, busyLabel,
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let detailScroll = NSScrollView()
        detailScroll.documentView = speakersStack
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        speakersStack.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        NSLayoutConstraint.activate([
            speakersStack.leadingAnchor.constraint(
                equalTo: detailScroll.contentView.leadingAnchor, constant: 4),
            speakersStack.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])

        let content = NSStackView(views: [
            scroll, detailTitle, openingLabel, detailScroll, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            openingLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            detailScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
        ])
        return container
    }

    // MARK: - data

    private func reload() {
        let previous = selected?.dir
        items = SessionInventory.scan(root: root)
        table.reloadData()
        if let previous, let row = items.firstIndex(where: { $0.dir == previous }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        showDetail()
    }

    private func showDetail() {
        speakersStack.arrangedSubviews.forEach {
            speakersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard let item = selected else {
            detailTitle.stringValue = items.isEmpty
                ? localised("No recordings yet", "Записей пока нет")
                : localised("Select a recording", "Выберите запись")
            openingLabel.stringValue = ""
            updateButtons()
            return
        }

        detailTitle.stringValue = item.title ?? item.name
        guard let transcript = PostProcessor.readTranscript(item.dir) else {
            openingLabel.stringValue = item.transcript == .pending
                ? localised("Not transcribed yet.", "Ещё не расшифровано.")
                : localised(
                    "No transcript — nothing to name.",
                    "Расшифровки нет — некому давать имена.")
            updateButtons()
            return
        }

        let names = SpeakerNames.read(from: item.dir)
        openingLabel.stringValue = SessionInventory.opening(of: transcript, names: names)
        for sample in SessionInventory.samples(transcript: transcript, names: names) {
            speakersStack.addArrangedSubview(speakerRow(sample, in: item.dir))
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
        finishButton.isEnabled = !working && (item?.isOutstanding ?? false)
        // Nothing to transcribe again once the audio is gone — and offering it
        // would be the cruellest button in the window, since pressing it
        // throws away the transcript that is now the only record there is.
        retranscribeButton.isEnabled = !working && (item?.hasAudio ?? false)
        openFolderButton.isEnabled = item != nil
        deleteButton.isEnabled = !working && item != nil
        busyLabel.stringValue = working ? localised("working…", "работаю…") : ""
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
        switch Self.decision(for: item) {
        case .refuse(let why):
            say(why, about: item)

        case .nothingOwed:
            say(Self.nothingOwedLine, about: item)

        // Asked without a confirmation, unlike Re-transcribe: there is no
        // transcript here for the work to throw away.
        case .transcribe(let clearingFirst):
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
                // Empty after all means the transcript could not be read —
                // the one thing the decision above cannot see. The command
                // line answers that the same way, and the session log has
                // the detail either way.
                if work.isEmpty { say(Self.nothingOwedLine, about: item) }
            }
        }
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

    /// Re-transcribing throws away a transcript that already exists, so it
    /// asks first — and says what survives, because the answer ("the audio")
    /// is the part that makes it safe.
    @objc private func retranscribeClicked() {
        guard let item = selected, item.hasAudio else { return }
        let alert = NSAlert()
        alert.messageText = localised(
            "Transcribe \(item.title ?? item.name) again?",
            "Расшифровать «\(item.title ?? item.name)» заново?")
        alert.informativeText = localised(
            """
            The current transcript, its speaker names and the summary are discarded \
            and made again from the audio, which is kept either way.
            """,
            """
            Нынешняя расшифровка, имена говорящих и саммари будут отброшены \
            и сделаны заново из звука, который остаётся в любом случае.
            """)
        alert.addButton(withTitle: localised("Transcribe again", "Расшифровать заново"))
        alert.addButton(withTitle: localised("Cancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PostProcessor.markForRetranscription(item.dir)
        onRetranscribe?(item.dir)
        reload()
    }

    @objc private func openFolderClicked() {
        guard let item = selected else { return }
        Analytics.track(.artifactOpened, [
            .artifact: .text(Analytics.Artifact.sessionFolder.rawValue),
        ])
        NSWorkspace.shared.activateFileViewerSelecting([item.dir])
    }

    /// To the Trash, never `rm`. These are meetings: the cost of a mistaken
    /// delete is somebody's only record of a conversation, and the Trash is
    /// what makes that recoverable.
    @objc private func deleteClicked() {
        guard let item = selected else { return }
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

    /// Called when a session is queued for transcription again, so the daemon
    /// can pick it up without waiting for the next launch.
    var onRetranscribe: ((URL) -> Void)?
}

extension RecordingsWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard row < items.count, let column = tableColumn?.identifier.rawValue else { return nil }
        return Self.cell(items[row], column: column)
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
