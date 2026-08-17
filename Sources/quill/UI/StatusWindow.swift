import AppKit

/// A small floating window with the same controls as the menu bar.
///
/// It exists because the menu bar is not a dependable place to put the only
/// control surface of a recorder. When it runs out of room macOS parks the
/// status item off-screen — position x = −9406 on this machine — and a menu
/// bar manager can hide it outright. The item stays clickable and completely
/// invisible, which for a program whose whole job is "am I recording?" is the
/// worst failure it can have.
///
/// So: a window you can leave in a corner, plus a Dock icon that shows the
/// same state. The menu bar item stays too — three ways to see one truth.
@MainActor
final class StatusWindow {
    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onOpenFolder: (() -> Void)?

    private let panel: NSPanel
    private let icon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "idle")
    private let transcriptionLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: "Start recording", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let autoRecordCheckbox = NSButton(checkboxWithTitle: "Record meetings automatically",
                                              target: nil, action: nil)
    private let decisionLabel = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 168),
            // A utility panel: it floats above ordinary windows and doesn't
            // take focus away from whatever you're doing during the meeting.
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "quill"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Closing must hide, not destroy: the Dock icon reopens this window.
        panel.isReleasedWhenClosed = false

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        transcriptionLabel.font = .systemFont(ofSize: 11)
        transcriptionLabel.textColor = .secondaryLabelColor
        transcriptionLabel.lineBreakMode = .byTruncatingTail
        decisionLabel.font = .systemFont(ofSize: 11)
        decisionLabel.textColor = .secondaryLabelColor
        decisionLabel.lineBreakMode = .byTruncatingTail

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        for button in [toggleButton, pauseButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        toggleButton.action = #selector(toggleClicked)
        pauseButton.action = #selector(pauseClicked)
        pauseButton.isEnabled = false

        autoRecordCheckbox.target = self
        autoRecordCheckbox.action = #selector(autoRecordClicked)

        let openFolder = NSButton(title: "Open recordings folder", target: self,
                                  action: #selector(openFolderClicked))
        openFolder.bezelStyle = .rounded

        let header = NSStackView(views: [icon, stateLabel])
        header.orientation = .horizontal
        header.spacing = 6

        let buttons = NSStackView(views: [toggleButton, pauseButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        let content = NSStackView(views: [
            header, transcriptionLabel, buttons, autoRecordCheckbox, decisionLabel, openFolder,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        // Buttons and the one-line statuses stretch to the window's width; a
        // long "why isn't it recording" line then truncates instead of
        // resizing the window on every tick.
        panel.contentView = content
        NSLayoutConstraint.activate([
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            transcriptionLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            decisionLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            openFolder.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
        ])

        panel.setFrameAutosaveName("quill.status")
        if panel.frame.origin == .zero { panel.center() }
        update(state: .idle, elapsed: nil)
    }

    /// Bring the window up without stealing keyboard focus from the meeting.
    func show() {
        panel.orderFrontRegardless()
    }

    func toggleVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func update(state: MenuBarController.State, elapsed: String?) {
        let recording = state != .idle
        icon.image = FeatherIcon.image(
            size: 18,
            color: FeatherIcon.color(recording: recording, paused: state == .paused)
        )
        switch state {
        case .idle:
            stateLabel.stringValue = "idle"
            stateLabel.textColor = .labelColor
            toggleButton.title = "Start recording"
            pauseButton.title = "Pause"
            pauseButton.isEnabled = false
        case .recording:
            stateLabel.stringValue = "● recording · \(elapsed ?? "0:00")"
            stateLabel.textColor = .systemRed
            toggleButton.title = "Stop recording"
            pauseButton.title = "Pause"
            pauseButton.isEnabled = true
        case .paused:
            stateLabel.stringValue = "❙❙ paused · \(elapsed ?? "0:00")"
            stateLabel.textColor = .systemOrange
            toggleButton.title = "Stop recording"
            pauseButton.title = "Resume"
            pauseButton.isEnabled = true
        }
    }

    func updateTranscription(_ text: String?) {
        transcriptionLabel.stringValue = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    func updateAutoRecord(enabled: Bool, decision: String?) {
        autoRecordCheckbox.state = enabled ? .on : .off
        decisionLabel.stringValue = decision ?? ""
        decisionLabel.isHidden = !enabled || decision == nil
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
}
