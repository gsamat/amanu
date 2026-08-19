import AppKit

/// The settings window: the setup form, and behind an Advanced tab, every
/// entry in `SettingsSchema`.
///
/// The first tab is not a copy of setup — it *is* setup, the same `SetupForm`
/// the first-run window wraps in a wizard. Two hand-written forms over one set
/// of settings drift the moment either is edited, and the settings window used
/// to be the poorer of the two: a flat list of thirty-odd keys, where setup
/// had the cards, the permission rows and the machine's own answers. Nothing
/// about that belonged only to the first run.
///
/// The Advanced tab is what setup deliberately doesn't ask: it holds no list
/// of its own, and that is the whole design. A window with its own copy of the
/// settings drifts from the code that reads them, and the settings that lose
/// the race become invisible — present in the program, absent from the window,
/// mentioned nowhere. Here the schema is the single list: add an entry there
/// and it appears, described, with its default showing, in this window. The
/// README is written by hand against the same list, and
/// `SettingsDocumentationTests` fails when the two drift.
///
/// Two rules make the config file stay readable as a record of decisions.
/// Nothing is written until it differs from the default — setting a control
/// back to the default *clears* the key rather than freezing today's default
/// into the file, so a default that improves later still reaches you. And an
/// emptied field means "unset", not "empty string". It is also why an empty
/// field shows the default in grey rather than nothing: an untouched setting
/// still has to say what it does.
@MainActor
final class SettingsWindow: NSObject, NSTextFieldDelegate {
    /// Forwarded to the setup form, which will not disturb a running
    /// recording to register a login item or play a test tone.
    var isRecording: (() -> Bool)? {
        didSet { setup.isRecording = isRecording }
    }

    private let panel: NSWindow
    private let setup = SetupForm()
    /// Redraws the Advanced tab when anything writes the config file. The
    /// Setup tab is a `SetupForm` and listens on its own.
    private var configWatch: ConfigWatch.Token?
    private var rows: [Row] = []
    /// What the setup window says in its footer, under the tab that shows the
    /// same form. Not a copy of the wizard's footer: the sentence comes from
    /// the form, and there is no button under it — in a settings window a
    /// button beside a list of settings reads as "apply", which is not what
    /// it would do.
    private let outstanding = NSTextField(labelWithString: "")
    private let restartNotice = NSTextField(labelWithString: "")
    private let strayKeys = NSTextField(labelWithString: "")

    /// One rendered setting: the entry it came from and the control showing
    /// it. The control's `tag` is this row's index, which is how an action
    /// finds its way back here.
    private struct Row {
        let entry: SettingsSchema.Entry
        let control: NSControl
    }

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
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
        panel.minSize = NSSize(width: 640, height: 460)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("Setup", holding: setupTab()))
        tabs.addTabViewItem(tab("Advanced", holding: SetupLayout.scroller(around: advancedForm())))

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

        // Under both tabs, because both write the same file: whichever tab
        // someone is on, this is where what they changed ended up.
        let footer = NSStackView(views: [restartNotice, strayKeys, pathLine])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabs)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content

        configWatch = ConfigWatch.observe { [weak self] in self?.refresh() }
        // Every redraw of the form ends here, whatever caused it — a grant
        // given in this window, a switch in the other one, a model that
        // finished downloading. The line is only true if it follows all of
        // them, and this is the seam the form already had.
        setup.onStateChange = { [weak self] in self?.showOutstanding() }
        showOutstanding()

        panel.setFrameAutosaveName("amanu.settings")
        if panel.frame.origin == .zero { panel.center() }
        refresh()
    }

    /// Bring the window up, re-reading the file first: the status window and
    /// the menu both write `auto_record.enabled`, and a settings window
    /// showing yesterday's answer is worse than no settings window.
    func show() {
        setup.reload()
        refresh()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// The controls of the Advanced tab, in schema order. This is where the
    /// window's whole promise — every setting appears, none is invisible —
    /// can be checked, so it's worth the accessor.
    var renderedControls: [NSControl] { rows.map(\.control) }

    /// What the Setup tab says is still outstanding — the wizard's footer
    /// sentence, under the same form.
    var outstandingLine: String { outstanding.stringValue }

    func hide() { panel.orderOut(nil) }

    // MARK: - building

    /// The form, and under it the one line saying whether anything is still
    /// outstanding. The hairline is the setup window's: below it is a report
    /// on the whole tab rather than another thing to fill in.
    private func setupTab() -> NSView {
        let scroll = SetupLayout.scroller(around: setup.view)
        let divider = SetupLayout.hairline()
        divider.translatesAutoresizingMaskIntoConstraints = false

        outstanding.font = .systemFont(ofSize: 12)
        outstanding.textColor = .secondaryLabelColor
        outstanding.lineBreakMode = .byTruncatingTail
        outstanding.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        // Constrained by `tab(_:holding:)` from outside, so it has to stop
        // resizing itself.
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        host.addSubview(divider)
        host.addSubview(outstanding)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            outstanding.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            outstanding.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: SetupLayout.gutter),
            outstanding.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor, constant: -SetupLayout.gutter),
            outstanding.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
        ])
        return host
    }

    /// The line under the Setup tab, from the form that computed it.
    private func showOutstanding() {
        outstanding.stringValue = setup.outstandingSentence
    }

    private func tab(_ label: String, holding view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let host = NSView()
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        item.view = host
        return item
    }

    private func advancedForm() -> NSView {
        let form = FlippedStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 12
        form.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        for (index, section) in SettingsSchema.sections.enumerated() {
            if index > 0 { form.setCustomSpacing(24, after: form.arrangedSubviews.last!) }
            form.addArrangedSubview(sectionHeader(section.title))
            for entry in section.entries {
                form.addArrangedSubview(makeRow(for: entry))
            }
        }
        return form
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makeRow(for entry: SettingsSchema.Entry) -> NSView {
        let control = makeControl(for: entry)
        control.tag = rows.count

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
        // Wide enough for the longest default to be read rather than
        // truncated: the placeholder is the only place some of them appear.
        default: controlWidth = 260
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
        rows.append(Row(entry: entry, control: control))

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
            // The grey text in an empty field is the default itself: where
            // it is a real value it can be read and copied, and where it is a
            // sentence ("the language of the meeting") that sentence is the
            // honest answer to what happens if you leave the field alone.
            field.placeholderString = SettingsSchema.describeDefault(entry)
            field.delegate = self
            field.target = self
            field.action = #selector(controlChanged(_:))
            return field
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
        // object may have just disappeared from the file entirely. The write
        // above has already redrawn every other surface, this one included;
        // an invalid entry never reaches it, which is why the guard clause
        // redraws by hand.
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
