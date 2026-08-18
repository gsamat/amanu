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

        panel.title = "Recordings"
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("amanu.recordings")

        buildTable()
        panel.contentView = buildLayout()
        if panel.frame.origin == .zero { panel.center() }
        reload()
    }

    func show() {
        reload()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - building

    private func buildTable() {
        let columns: [(String, String, CGFloat)] = [
            ("when", "When", 130),
            ("meeting", "Meeting", 250),
            ("transcript", "Transcript", 150),
            ("names", "Names", 110),
            ("summary", "Summary", 90),
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
        openingLabel.textColor = .secondaryLabelColor
        openingLabel.lineBreakMode = .byTruncatingTail
        busyLabel.font = .systemFont(ofSize: 11)
        busyLabel.textColor = .secondaryLabelColor

        speakersStack.orientation = .vertical
        speakersStack.alignment = .leading
        speakersStack.spacing = 6

        for (button, title, action) in [
            (finishButton, "Finish processing", #selector(finishClicked)),
            (retranscribeButton, "Re-transcribe", #selector(retranscribeClicked)),
            (openFolderButton, "Open folder", #selector(openFolderClicked)),
            (deleteButton, "Delete", #selector(deleteClicked)),
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
            detailTitle.stringValue = items.isEmpty ? "No recordings yet" : "Select a recording"
            openingLabel.stringValue = ""
            updateButtons()
            return
        }

        detailTitle.stringValue = item.title ?? item.name
        guard let transcript = PostProcessor.readTranscript(item.dir) else {
            openingLabel.stringValue = item.transcript == .pending
                ? "Not transcribed yet."
                : "No transcript — nothing to name."
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
        let label = NSTextField(labelWithString: sample.label)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let field = NSTextField(string: sample.name ?? "")
        field.placeholderString = "name"
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        field.target = self
        field.action = #selector(nameEdited(_:))
        field.identifier = .init("\(dir.path)\n\(sample.label)")

        let provenance = NSTextField(labelWithString: sample.source.map {
            "\($0.rawValue) · \(sample.turns) turns"
        } ?? "\(sample.turns) turns")
        provenance.font = .systemFont(ofSize: 10)
        provenance.textColor = .tertiaryLabelColor

        let head = NSStackView(views: [label, field, provenance])
        head.orientation = .horizontal
        head.spacing = 8

        let quotes = NSTextField(wrappingLabelWithString: [
            sample.first.isEmpty ? nil : "first: \(sample.first)",
            sample.longest == sample.first || sample.longest.isEmpty
                ? nil : "longest: \(sample.longest)",
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
        busyLabel.stringValue = working ? "working…" : ""
    }

    // MARK: - actions

    @objc private func nameEdited(_ sender: NSTextField) {
        guard let id = sender.identifier?.rawValue else { return }
        let parts = id.components(separatedBy: "\n")
        guard parts.count == 2 else { return }
        PostProcessor.rename(parts[1], to: sender.stringValue, in: URL(fileURLWithPath: parts[0]))
        reload()
    }

    @objc private func finishClicked() {
        guard let item = selected else { return }
        working = true
        updateButtons()
        Task {
            await PostProcessor.finish(item.dir)
            working = false
            reload()
        }
    }

    /// Re-transcribing throws away a transcript that already exists, so it
    /// asks first — and says what survives, because the answer ("the audio")
    /// is the part that makes it safe.
    @objc private func retranscribeClicked() {
        guard let item = selected, item.hasAudio else { return }
        let alert = NSAlert()
        alert.messageText = "Transcribe \(item.title ?? item.name) again?"
        alert.informativeText = """
            The current transcript, its speaker names and the summary are discarded \
            and made again from the audio, which is kept either way.
            """
        alert.addButton(withTitle: "Transcribe again")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PostProcessor.markForRetranscription(item.dir)
        onRetranscribe?(item.dir)
        reload()
    }

    @objc private func openFolderClicked() {
        guard let item = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.dir])
    }

    /// To the Trash, never `rm`. These are meetings: the cost of a mistaken
    /// delete is somebody's only record of a conversation, and the Trash is
    /// what makes that recoverable.
    @objc private func deleteClicked() {
        guard let item = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(item.title ?? item.name) to the Trash?"
        alert.informativeText = "The recording, its transcript and its summary go together."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
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
        let item = items[row]
        switch column {
        case "when":
            return item.started.map { SessionInventory.Item.stamp.string(from: $0) } ?? item.name
        case "meeting":
            let length = item.duration.map { " · \(Int($0 / 60))m" } ?? ""
            return (item.title ?? item.name) + length
        case "transcript":
            return item.transcript.label + (item.engine.map { " (\($0))" } ?? "")
        case "names":
            guard let counts = item.namedSpeakers, counts.total > 0 else {
                return item.speakers.label
            }
            return "\(counts.named)/\(counts.total)"
        case "summary":
            return item.summary.label
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail()
    }
}
