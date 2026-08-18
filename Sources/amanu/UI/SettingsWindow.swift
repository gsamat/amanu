import AppKit

/// The settings window: every entry in `SettingsSchema`, rendered.
///
/// It holds no list of its own, and that is the whole design. A window with
/// its own copy of the settings drifts from the code that reads them, and the
/// settings that lose the race become invisible — present in the program,
/// absent from the window, mentioned nowhere. Here the schema is the single
/// list: add an entry there and it appears, described, with its default
/// showing, in this window. The README is written by hand against the same
/// list, and `SettingsDocumentationTests` fails when the two drift.
///
/// Two rules make the config file stay readable as a record of decisions.
/// Nothing is written until it differs from the default — setting a control
/// back to the default *clears* the key rather than freezing today's default
/// into the file, so a default that improves later still reaches you. And an
/// emptied field means "unset", not "empty string".
@MainActor
final class SettingsWindow: NSObject, NSTextFieldDelegate {
    private let panel: NSWindow
    private var rows: [Row] = []
    private let restartNotice = NSTextField(labelWithString: "")
    private let strayKeys = NSTextField(labelWithString: "")

    /// One rendered setting: the entry it came from and the control showing it.
    /// The control's `tag` is this row's index, which is how an action finds
    /// its way back here.
    private struct Row {
        let entry: SettingsSchema.Entry
        let control: NSControl
    }

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "amanu settings"
        panel.level = .normal
        panel.hidesOnDeactivate = false
        // Closing hides; the menu reopens it. Same reasoning as the status
        // window — the program outlives its windows.
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        form.translatesAutoresizingMaskIntoConstraints = false

        for (index, section) in SettingsSchema.sections.enumerated() {
            if index > 0 { form.setCustomSpacing(24, after: form.arrangedSubviews.last!) }
            form.addArrangedSubview(sectionHeader(section.title))
            for entry in section.entries {
                form.addArrangedSubview(makeRow(for: entry))
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = form
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Pinned to the clip view on three sides: the height stays intrinsic,
        // which is what makes the thing scroll rather than squash.
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        for label in [restartNotice, strayKeys] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.isHidden = true
        }
        strayKeys.textColor = .systemOrange

        let path = NSTextField(labelWithString: Config.path.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle

        let reveal = NSButton(title: "Reveal config", target: self,
                              action: #selector(revealConfigClicked))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small

        let pathLine = NSStackView(views: [path, reveal])
        pathLine.orientation = .horizontal
        pathLine.spacing = 10

        let footer = NSStackView(views: [restartNotice, strayKeys, pathLine])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

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

        panel.setFrameAutosaveName("amanu.settings")
        if panel.frame.origin == .zero { panel.center() }
        refresh()
    }

    /// Bring the window up, re-reading the file first: the status window and
    /// the menu both write `auto_record.enabled`, and a settings window
    /// showing yesterday's answer is worse than no settings window.
    func show() {
        refresh()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// The controls actually rendered, in schema order. This is where the
    /// window's whole promise — every setting appears, none is invisible —
    /// can be checked, so it's worth the accessor.
    var renderedControls: [NSControl] { rows.map(\.control) }

    func hide() { panel.orderOut(nil) }

    // MARK: - building

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeRow(for entry: SettingsSchema.Entry) -> NSView {
        let control = makeControl(for: entry)
        control.tag = rows.count
        rows.append(Row(entry: entry, control: control))

        let label = NSTextField(labelWithString: entry.label)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [label, control])
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 10

        // A toggle is a small thing on the right of a wide label; a text field
        // wants room. Both keep the same column so the window reads as a form.
        let controlWidth: CGFloat
        switch entry.kind {
        case .toggle: controlWidth = 40
        case .number: controlWidth = 110
        default: controlWidth = 190
        }
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 260),
            control.widthAnchor.constraint(equalToConstant: controlWidth),
        ])

        var helpText = entry.help
        if entry.needsRestart { helpText += " Takes effect at the next launch." }
        let help = NSTextField(labelWithString: helpText)
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byWordWrapping
        help.maximumNumberOfLines = 0
        help.preferredMaxLayoutWidth = 460

        let row = NSStackView(views: [line, help])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }

    private func makeControl(for entry: SettingsSchema.Entry) -> NSControl {
        switch entry.kind {
        case .toggle:
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(controlChanged(_:))
            return toggle

        case .choice(let options):
            let popup = NSPopUpButton()
            popup.addItems(withTitles: options)
            popup.target = self
            popup.action = #selector(controlChanged(_:))
            return popup

        case .number, .text, .list:
            let field = NSTextField()
            field.placeholderString = placeholder(for: entry)
            field.delegate = self
            field.target = self
            field.action = #selector(controlChanged(_:))
            return field
        }
    }

    /// What the field shows when nothing is set. Where a default is a real
    /// value it's shown verbatim, so it can be copied; where it's a sentence
    /// ("the language of the meeting") that sentence is the honest answer.
    private func placeholder(for entry: SettingsSchema.Entry) -> String {
        switch entry.kind {
        case .number(let unit):
            return "\(entry.defaultValue) \(unit)"
        case .text(let placeholder):
            return placeholder
        default:
            return "\(entry.defaultValue)"
        }
    }

    // MARK: - reading and writing

    /// Redraw every control from the config file.
    private func refresh() {
        let config = Config.raw()
        for row in rows {
            let stored = value(at: row.entry.path, in: config)
            switch row.entry.kind {
            case .toggle:
                let on = stored as? Bool ?? row.entry.defaultValue as? Bool ?? false
                (row.control as? NSSwitch)?.state = on ? .on : .off
            case .choice:
                let selected = stored as? String ?? row.entry.defaultValue as? String
                if let selected { (row.control as? NSPopUpButton)?.selectItem(withTitle: selected) }
            case .list:
                let items = stored as? [String] ?? []
                row.control.stringValue = items.joined(separator: ", ")
            case .number, .text:
                row.control.stringValue = stored.map { "\($0)" } ?? ""
            }
        }
        showStrayKeys(in: config)
    }

    private func value(at path: [String], in config: [String: Any]) -> Any? {
        var node: Any? = config
        for key in path {
            guard let object = node as? [String: Any] else { return nil }
            node = object[key]
        }
        return node
    }

    @objc private func controlChanged(_ sender: NSControl) {
        commit(rows[sender.tag])
    }

    /// Enter isn't the only way to leave a text field, and a setting that took
    /// effect only when you remembered to press it would be a bug people
    /// blamed on the recorder.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSControl else { return }
        commit(rows[field.tag])
    }

    private func commit(_ row: Row) {
        let entry = row.entry
        let input: SettingsSchema.Input
        switch entry.kind {
        case .toggle:
            input = .flag((row.control as? NSSwitch)?.state == .on)
        case .choice:
            input = .choice((row.control as? NSPopUpButton)?.titleOfSelectedItem ?? "")
        case .number, .text, .list:
            input = .text(row.control.stringValue)
        }

        switch SettingsSchema.resolve(input, for: entry) {
        case .set(let value):
            Config.update(path: entry.path, value: value)
        case .clear:
            Config.update(path: entry.path, value: nil)
        case .invalid:
            // Letters in a number field: put back what is actually stored
            // rather than writing a guess or leaving the field lying.
            refresh()
            return
        }

        if entry.needsRestart {
            restartNotice.stringValue =
                "“\(entry.label)” applies the next time amanu starts."
            restartNotice.isHidden = false
        }
        // Clearing can change what a field should show — an emptied field goes
        // back to displaying its default as a placeholder — and a nested
        // object may have just disappeared from the file entirely.
        refresh()
    }

    /// Keys in the file that nothing reads: a typo, or a setting from a
    /// version that had it. Worth saying out loud, because the failure looks
    /// exactly like a setting being ignored — which it is.
    private func showStrayKeys(in config: [String: Any]) {
        let stray = SettingsSchema.strayKeys(in: config)
        strayKeys.stringValue = stray.isEmpty
            ? ""
            : "Not read by this version: \(stray.joined(separator: ", "))"
        strayKeys.isHidden = stray.isEmpty
    }

    @objc private func revealConfigClicked() {
        // The file may not exist yet — nothing has been changed from its
        // default — so open the folder rather than selecting nothing.
        if FileManager.default.fileExists(atPath: Config.path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Config.path])
        } else {
            NSWorkspace.shared.open(Config.path.deletingLastPathComponent())
        }
    }
}
