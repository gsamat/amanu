import AppKit

/// The setup window's grid and type scale, in one place.
///
/// Everything in that window is one of four shapes — a section, a list of
/// rows, a row, or a card — and every one of them used to carry its own
/// hand-written insets and font sizes. Sizes chosen a few lines apart drift,
/// and a window whose rows are 9pt tall in one box and 13pt in the next looks
/// like it was assembled rather than designed.
///
/// So the numbers live here and the window asks for shapes.
@MainActor
enum SetupLayout {
    /// The window's own margin, and the distance between two sections. A
    /// section is closer to its own heading than to its neighbours — that
    /// proximity is what makes the grouping readable without more borders.
    static let gutter: CGFloat = 24
    static let sectionGap: CGFloat = 30
    static let headerGap: CGFloat = 8
    static let groupGap: CGFloat = 16
    static let cardGap: CGFloat = 12
    static let corner: CGFloat = 10

    static let rowInsets = NSEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
    static let cardInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

    /// The least a row may be. Two rows carrying one line each have to come
    /// out the same height, and before this they did not: the height followed
    /// the flexible gap below, which is constrained in neither direction, so
    /// the row that still had a button came out 44pt and its neighbours 36pt.
    /// Everything in a row is aligned to the top, so those eight points landed
    /// under the text and read as a wider gap above the row beneath — which is
    /// how the Calendar row came to look further from its neighbour than the
    /// rest of the list.
    static let rowHeight: CGFloat = 44

    /// Four sizes, each with one job: a muted label for the group, the line
    /// you read, the line that explains it, and the machine's own report.
    static let sectionFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 14)
    static let detailFont = NSFont.systemFont(ofSize: 12)
    static let statusFont = NSFont.systemFont(ofSize: 11)
    static var monoFont: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    // MARK: - labels

    static func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = titleFont
        return label
    }

    static func detail(_ text: String, lines: Int = 3, width: CGFloat = 460) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = detailFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = lines
        label.preferredMaxLayoutWidth = width
        return label
    }

    static func status(_ text: String = "") -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = statusFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // MARK: - shapes

    /// A heading and what it heads, kept together. `leading` is for a control
    /// that governs the whole section — the Summaries switch — which sits
    /// before the words for the same reason a light switch sits beside a door.
    static func section(_ name: String, leading: NSView? = nil, content: NSView) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = sectionFont
        label.textColor = .secondaryLabelColor

        let heading = NSStackView(views: leading.map { [$0, label] } ?? [label])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10

        let stack = NSStackView(views: [heading, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = headerGap
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Several things under one heading, each as wide as the section.
    static func group(_ views: [NSView], spacing: CGFloat = groupGap) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Rows in a bordered container with hairlines between them — the shape
    /// macOS uses everywhere for a list of settings.
    static func box(_ rows: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.wantsLayer = true
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.layer?.cornerRadius = corner

        for (index, row) in rows.enumerated() {
            if index > 0 { stack.addArrangedSubview(hairline()) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// The gap that pushes whatever follows it to the trailing edge. It has
    /// no intrinsic size of its own, so it is pinned flat: left free it takes
    /// the height of the row with it, and the row stops describing its
    /// content. Only the horizontal stretch is wanted here.
    static func spacer() -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: 0).isActive = true
        return view
    }

    static func hairline() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// One row of a box: something to operate on the left, words in the
    /// middle, and whatever reports or acts on the right.
    static func row(
        leading: NSView? = nil,
        symbol: String? = nil,
        title: NSView,
        detail: NSView? = nil,
        trailing: [NSView] = []
    ) -> NSView {
        var views: [NSView] = []
        if let leading { views.append(leading) }
        if let symbol {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(icon)
        }

        let words = NSStackView(views: detail.map { [title, $0] } ?? [title])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 2
        // The words are part of the switch, as the title of a checkbox is
        // part of the checkbox. Aiming at a 50pt switch is a worse target
        // than aiming at the sentence that says what it does.
        let toggle = (leading as? NSSwitch)
            ?? trailing.compactMap { $0 as? NSSwitch }.first
        if let toggle {
            words.addGestureRecognizer(NSClickGestureRecognizer(
                target: toggle, action: #selector(NSSwitch.toggleFromItsLabel)))
        }
        views.append(words)
        views.append(spacer())
        views.append(contentsOf: trailing)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        // Centred when the row is one line, top-aligned when the words wrap:
        // a switch floating beside the middle of a paragraph reads as loose.
        stack.alignment = detail == nil ? .centerY : .top
        stack.spacing = 10
        stack.edgeInsets = rowInsets
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight).isActive = true
        return stack
    }

    /// A row of mutually exclusive cards, all the same width.
    static func cards(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = cardGap
        return stack
    }

    static func actionButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    /// A link is an ordinary button whose identifier carries the destination,
    /// so one handler opens whichever one was clicked. It is drawn as a link
    /// rather than as a small grey pill: a pill beside a card's own controls
    /// reads as another thing to press, and this one only opens a web page.
    static func link(_ title: String, _ url: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.attributedTitle = NSAttributedString(
            string: "\(title) ↗",
            attributes: [
                .font: statusFont,
                .foregroundColor: NSColor.linkColor,
            ])
        button.identifier = NSUserInterfaceItemIdentifier(url)
        return button
    }
}

extension NSSwitch {
    /// Toggling from something else that was clicked on the switch's behalf.
    /// The gesture recogniser holds its target weakly, so the switch is its
    /// own target: it is the one thing here the view hierarchy keeps alive.
    @objc func toggleFromItsLabel() {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        sendAction(action, to: target)
    }
}
