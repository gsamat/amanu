import AppKit

/// The window a new installation opens by itself: `SetupForm` in a wizard's
/// clothes.
///
/// The form is the same one the settings window shows; what this adds is the
/// wizard around it — a footer saying what is still outstanding, and one
/// button that does the next thing that has to happen. That ordering matters
/// on a first run and nowhere else: macOS shows one permission dialog at a
/// time, and a grant given to the wrong process is worse than no grant.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    /// Whether a recording is in progress. Registering at login and testing
    /// system audio both disturb a running recording, and nothing in this
    /// window is worth losing a meeting for.
    var isRecording: (() -> Bool)? {
        didSet { form.isRecording = isRecording }
    }
    /// Called when the window has done everything it can and been dismissed.
    var onFinished: (() -> Void)?

    private let panel: NSWindow
    private let form = SetupForm()
    private let footerNote = NSTextField(labelWithString: "")
    private let primary = NSButton(
        title: localised("Done", "Готово"), target: nil, action: nil)

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = localised("amanu setup", "Первая настройка amanu")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 640, height: 460)

        let scroll = SetupLayout.scroller(around: form.view)

        footerNote.font = .systemFont(ofSize: 12)
        footerNote.textColor = .secondaryLabelColor
        footerNote.lineBreakMode = .byTruncatingTail

        let later = NSButton(
            title: localised("Later", "Позже"), target: self, action: #selector(laterClicked))
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

        form.onStateChange = { [weak self] in self?.updateFooter() }
        updateFooter()
    }

    func show() {
        if !panel.isVisible { Analytics.track(.setupOpened) }
        form.reload()
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish()
        return false
    }

    @objc private func laterClicked() {
        finish()
    }

    @objc private func primaryClicked() {
        // The button does the next unfinished thing, and only closes when
        // there is nothing left it can do from here.
        if let next = form.nextAction {
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
        SetupState.markCompleted()
        form.stop()
        panel.orderOut(nil)
        onFinished?()
    }

    /// The one line above the buttons, and what the button itself says. Both
    /// are the form's answers — this only arranges them.
    private func updateFooter() {
        footerNote.stringValue = form.outstandingSentence
        primary.title = form.nextActionTitle
        primary.isEnabled = !form.isDownloading
    }
}
