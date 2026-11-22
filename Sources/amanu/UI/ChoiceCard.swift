import AppKit

/// A card in a row of mutually exclusive choices.
///
/// A radio button as far as anything but the eye is concerned. It was a plain
/// view that answered the mouse and nothing else, so choosing a transcription
/// provider, a local engine or a summary backend could not be done from the
/// keyboard at all, and VoiceOver passed over the cards as a stretch of
/// unlabelled text. It takes focus, draws the focus ring around its whole
/// outline, chooses itself on Space or Return, moves to its neighbour on the
/// arrow keys, and says to the accessibility API what it is, what it is
/// called and whether it is the one chosen.
@MainActor
final class ChoiceCard: NSView, LayerTinted {
    let id: String
    var onSelect: ((String) -> Void)?
    /// Move to the card `offset` places along in the same group; set by the
    /// group, which is the only thing that knows the order.
    var onStep: ((_ offset: Int) -> Void)?

    private let radio = NSImageView()
    private let titleLabel: NSTextField
    private let statusLabel = NSTextField(labelWithString: "")
    private var linkButton: NSButton?
    private var selected = false

    /// What the machine last said about this card. Set through `report`,
    /// which is also told whether that was good news.
    private(set) var status: String = "" {
        didSet {
            statusLabel.stringValue = status
            statusLabel.isHidden = status.isEmpty
            colourStatus()
        }
    }

    /// Say what the machine answered, and whether it was the answer somebody
    /// wanted.
    ///
    /// Good news used to be recognised by matching the words — anything
    /// starting with "answers", "downloaded", "key works" or "running" was
    /// green. That is a rule that only reads one language: translate the
    /// statuses and every card in the window goes grey, which is a defect
    /// nothing would have failed on. The caller knows the answer it just got;
    /// it says so.
    func report(_ text: String, good: Bool = false) {
        works = good
        status = text
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

    /// What the card is called, and what it says beneath that — the words a
    /// screen reader has to say for it, since the labels themselves are not
    /// what gets focus.
    private let title: String
    private let detail: String

    var isSelected: Bool {
        get { selected }
        set {
            selected = newValue
            radio.image = NSImage(
                systemSymbolName: newValue ? "largecircle.fill.circle" : "circle",
                accessibilityDescription: newValue
                    ? localised("chosen", "выбрано")
                    : localised("not chosen", "не выбрано"))
            radio.contentTintColor = newValue ? .controlAccentColor : .tertiaryLabelColor
            layer?.borderWidth = newValue ? 1.5 : 1
            retint()
            colourStatus()
        }
    }

    init(id: String, title: String, detail: String, accessories: [NSView] = [],
         compact: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("choice.\(id)")

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
            ? NSStackView(
                views: [heading, detailLabel, SetupLayout.spacer(), statusLabel] + accessories)
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
        guard !compact else {
            // A compact card is a row, and rows state their own height here
            // rather than inheriting whatever the stack settles on — the same
            // arithmetic `SetupLayout.row` gets, so there is one answer to
            // this question in the window and not two.
            SetupLayout.fitRowHeight(stack)
            return
        }
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: stack.trailingAnchor,
            constant: -SetupLayout.cardInsets.right).isActive = true
        for accessory in accessories where !(accessory is NSButton) {
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

    // MARK: - keyboard

    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds, xRadius: SetupLayout.corner, yRadius: SetupLayout.corner
        ).fill()
    }

    /// Space and Return choose, as they press a radio button; the arrows move
    /// along the row, as they do in a radio group.
    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return super.keyDown(with: event) }
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            onSelect?(id)
        case .leftArrow?, .upArrow?:
            onStep?(-1)
        case .rightArrow?, .downArrow?:
            onStep?(1)
        default:
            if event.charactersIgnoringModifiers == " " {
                onSelect?(id)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { NSNumber(value: selected ? 1 : 0) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func isAccessibilitySelected() -> Bool { selected }

    /// The description and what the machine said about it, read after the
    /// name: "OpenAI, radio button, selected — $0.36 an hour. key works".
    override func accessibilityHelp() -> String? {
        [detail, status].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onSelect?(id)
        return true
    }
}

/// A set of cards where exactly one is chosen. AppKit only groups radio
/// buttons that share a superview, and these deliberately don't — so the
/// grouping is done here, in the open.
@MainActor
final class ChoiceGroup {
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
            card.onStep = { [weak self, weak card] offset in
                guard let self, let card else { return }
                self.step(from: card, by: offset)
            }
        }
    }

    /// An arrow key on a card: focus and choose the next enabled card along,
    /// the way arrows move the choice in any radio group.
    private func step(from card: ChoiceCard, by offset: Int) {
        guard let start = cards.firstIndex(where: { $0 === card }) else { return }
        var index = start + offset
        while cards.indices.contains(index) {
            let next = cards[index]
            if next.isEnabled, !next.isHiddenOrHasHiddenAncestor {
                next.window?.makeFirstResponder(next)
                next.onSelect?(next.id)
                return
            }
            index += offset
        }
    }

    func card(_ id: String) -> ChoiceCard? { cards.first { $0.id == id } }

    func select(_ id: String?) {
        for card in cards { card.isSelected = card.id == id }
    }
}
