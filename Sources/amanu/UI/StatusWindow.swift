import AppKit

/// A small ordinary window with the same controls as the menu bar.
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
    var onToggleLive: ((Bool) -> Void)?
    var onOpenFolder: (() -> Void)?
    var onShowRecordings: (() -> Void)?

    private let panel: NSWindow
    private let icon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: localised("idle", "не записывает"))
    private let transcriptionLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(
        title: localised("Start recording", "Начать запись"), target: nil, action: nil)
    private let pauseButton = NSButton(
        title: localised("Pause", "Пауза"), target: nil, action: nil)
    private let autoRecordCheckbox = NSButton(
        checkboxWithTitle: localised("Record meetings automatically", "Записывать встречи сама"),
        target: nil, action: nil)
    private let decisionLabel = NSTextField(labelWithString: "")
    private let liveCheckbox = NSButton(
        checkboxWithTitle: localised("Live transcript", "Расшифровка на ходу"),
        target: nil, action: nil)
    private let liveStatus = NSTextField(labelWithString: "")
    private let liveReveal = NSButton(title: "Show transcript", target: nil, action: nil)
    private let liveText = NSTextView()
    private let liveScroll = NSScrollView()
    private let liveSection = NSStackView()

    /// The window is deliberately small. It answers one question — am I being
    /// recorded — and a recorder that needs a big window to say so is a worse
    /// recorder. The live transcript is the one thing that needs room, so it
    /// borrows it while it runs and gives it back afterwards.
    private static let compactSize = NSSize(width: 320, height: 210)
    private static let expandedHeight: CGFloat = 460
    private var liveTextVisible = false
    private var heightBeforeLive: CGFloat?
    private var liveRevealedAfterStop = false

    init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.compactSize.width,
                                height: Self.compactSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "amanu"
        // An ordinary window at the ordinary level: it goes behind whatever
        // you bring forward, like everything else. State that must be visible
        // without hunting for a window is the Dock icon's job — it turns red
        // while recording — so this one doesn't need to sit on top of your
        // work all day.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        // Closing must hide, not destroy: the Dock icon reopens this window.
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.compactSize

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

        liveCheckbox.target = self
        liveCheckbox.action = #selector(liveClicked)
        liveCheckbox.isEnabled = true
        liveStatus.font = .systemFont(ofSize: 11)
        liveStatus.textColor = .secondaryLabelColor
        liveStatus.lineBreakMode = .byTruncatingTail

        // The way back to a transcript the end of the recording folded away.
        // It sits where the status line does: a recording that has stopped
        // has no status to report, so the row has the space free.
        liveReveal.isBordered = false
        liveReveal.target = self
        liveReveal.action = #selector(liveRevealClicked)
        liveReveal.isHidden = true
        setRevealTitle("Show transcript")

        liveText.isEditable = false
        liveText.isSelectable = true
        liveText.drawsBackground = false
        liveText.font = .systemFont(ofSize: 12)
        liveText.textContainerInset = NSSize(width: 8, height: 8)
        liveText.isVerticallyResizable = true
        liveText.isHorizontallyResizable = false
        liveText.autoresizingMask = [.width]
        liveText.textContainer?.widthTracksTextView = true
        liveScroll.documentView = liveText
        liveScroll.hasVerticalScroller = true
        liveScroll.autohidesScrollers = true
        liveScroll.drawsBackground = false
        liveScroll.borderType = .bezelBorder
        liveScroll.isHidden = true

        let liveHeader = NSStackView(views: [liveCheckbox, NSView(), liveStatus, liveReveal])
        liveHeader.orientation = .horizontal
        liveHeader.spacing = 8
        liveSection.setViews([liveHeader, liveScroll], in: .top)
        liveSection.orientation = .vertical
        liveSection.alignment = .leading
        liveSection.spacing = 6
        // The live transcript runs a local streaming model. On an Intel Mac
        // there is none, so the checkbox would be an offer that turns itself
        // back off — hidden instead, and the window stays compact.
        liveSection.isHidden = !Platform.supportsLocalModels

        let openFolder = NSButton(
            title: localised("Open recordings folder", "Открыть папку записей"),
            target: self, action: #selector(openFolderClicked))
        openFolder.bezelStyle = .rounded

        let manage = NSButton(
            title: localised("Manage recordings…", "Управление записями…"),
            target: self, action: #selector(showRecordingsClicked))
        manage.bezelStyle = .rounded

        let header = NSStackView(views: [icon, stateLabel])
        header.orientation = .horizontal
        header.spacing = 6

        let buttons = NSStackView(views: [toggleButton, pauseButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 8

        let content = NSStackView(views: [
            header, transcriptionLabel, buttons, autoRecordCheckbox, decisionLabel,
            openFolder, manage, liveSection,
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
            manage.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            liveSection.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            liveScroll.widthAnchor.constraint(equalTo: liveSection.widthAnchor),
            liveScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        panel.setFrameAutosaveName("amanu.status")
        if panel.frame.origin == .zero { panel.center() }
        // The autosaved frame remembers whatever height the window last had —
        // including the tall one it takes while a live transcript is running.
        // Idle, it opens compact again; the position is still remembered.
        if panel.frame.height > Self.compactSize.height {
            resize(to: Self.compactSize.height)
        }
        update(state: .idle, elapsed: nil)
    }

    /// Bring the window up. orderFront rather than makeKey: at login this
    /// runs unattended, and a window that grabs the keyboard while you're
    /// typing is its own kind of rude. Clicking the Dock icon activates the
    /// app anyway, which brings it properly forward.
    func show() {
        panel.orderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        panel.orderOut(nil)
    }

    func update(state: MenuBarController.State, elapsed: String?) {
        let recording = state != .idle
        icon.image = FeatherIcon.image(
            size: 18,
            color: FeatherIcon.color(recording: recording, paused: state == .paused)
        )
        switch state {
        case .idle:
            stateLabel.stringValue = localised("idle", "не записывает")
            stateLabel.textColor = .labelColor
            toggleButton.title = localised("Start recording", "Начать запись")
            pauseButton.title = localised("Pause", "Пауза")
            pauseButton.isEnabled = false
        case .recording:
            stateLabel.stringValue =
                localised("● recording · ", "● запись · ") + (elapsed ?? "0:00")
            stateLabel.textColor = .systemRed
            toggleButton.title = localised("Stop recording", "Остановить запись")
            pauseButton.title = localised("Pause", "Пауза")
            pauseButton.isEnabled = true
        case .paused:
            stateLabel.stringValue =
                localised("❙❙ paused · ", "❙❙ пауза · ") + (elapsed ?? "0:00")
            stateLabel.textColor = .systemOrange
            toggleButton.title = localised("Stop recording", "Остановить запись")
            pauseButton.title = localised("Resume", "Продолжить")
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

    func updateLive(_ snapshot: LiveTranscriptionCoordinator.Snapshot) {
        if snapshot.isRecording {
            liveCheckbox.state = snapshot.isEnabled ? .on : .off
        }
        liveStatus.stringValue = switch snapshot.status {
        case .idle: ""
        case .paused: localised("off", "выключена")
        case .loading: localised("loading model…", "загружаю модель…")
        case .live: localised("on this Mac", "на этом маке")
        case .modelMissing: localised("model not downloaded", "модель не скачана")
        case .overloaded:
            localised("stopped — Mac couldn't keep up", "остановлена — мак не успевает")
        case .error(let message): localised("stopped — ", "остановлена — ") + message
        }

        let rendered = NSMutableAttributedString()
        for entry in snapshot.entries {
            switch entry {
            case .resumed:
                rendered.append(NSAttributedString(
                    string: localised(
                        "\n— live transcript resumed —\n\n",
                        "\n— расшифровка продолжена —\n\n"),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
            case .speech(let block):
                rendered.append(NSAttributedString(
                    string: "\(block.speaker.label)  ",
                    attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
                rendered.append(NSAttributedString(
                    string: block.text + "\n\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: block.isProvisional
                            ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    ]))
            }
        }

        let documentHeight = liveText.layoutManager?.usedRect(
            for: liveText.textContainer!).height ?? 0
        let visibleBottom = liveScroll.contentView.bounds.maxY
        let wasAtBottom = documentHeight - visibleBottom < 24
        liveText.textStorage?.setAttributedString(rendered)
        if wasAtBottom { liveText.scrollToEndOfDocument(nil) }
        if snapshot.isRecording { liveRevealedAfterStop = false }
        let visibility = Self.liveTextVisibility(
            for: snapshot, revealed: liveRevealedAfterStop)
        showLiveText(visibility.showsTranscript)
        liveReveal.isHidden = !visibility.showsRevealLink
    }

    struct LiveTextVisibility: Equatable, Sendable {
        var showsTranscript: Bool
        var showsRevealLink: Bool
    }

    /// An empty bordered box under a failed or idle live section is just a
    /// hole in the window: while recording, show it once there is text or
    /// text is on its way. The end of the recording folds it away again — the
    /// meeting is over, and a status window has no reason to stay tall for a
    /// transcript nobody is reading any more — but the text is still there
    /// behind a link until the next recording clears it.
    nonisolated static func liveTextVisibility(
        for snapshot: LiveTranscriptionCoordinator.Snapshot,
        revealed: Bool
    ) -> LiveTextVisibility {
        let hasText = !snapshot.entries.isEmpty
        let expecting = snapshot.status == .loading || snapshot.status == .live
        guard !snapshot.isRecording else {
            return LiveTextVisibility(
                showsTranscript: hasText || expecting, showsRevealLink: false)
        }
        return LiveTextVisibility(
            showsTranscript: hasText && revealed, showsRevealLink: hasText)
    }

    /// Grow only on the way in, and only from a compact window: someone who
    /// has dragged this taller keeps their size, and the height they get back
    /// when live stops is the one the window had before it expanded.
    private func showLiveText(_ visible: Bool) {
        guard visible != liveTextVisible else { return }
        liveTextVisible = visible
        liveScroll.isHidden = !visible
        setRevealTitle(visible ? "Hide" : "Show transcript")

        if visible {
            panel.minSize = NSSize(width: Self.compactSize.width, height: 320)
            guard panel.frame.height < Self.expandedHeight else { return }
            heightBeforeLive = panel.frame.height
            resize(to: Self.expandedHeight)
        } else {
            panel.minSize = Self.compactSize
            guard let restored = heightBeforeLive else { return }
            heightBeforeLive = nil
            guard panel.frame.height > restored else { return }
            resize(to: restored)
        }
    }

    /// Keep the title bar where it is: a window that grows downward off the
    /// screen edge is how a status window ends up half-visible.
    private func resize(to height: CGFloat) {
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func setRevealTitle(_ title: String) {
        liveReveal.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
            ])
    }

    func updateLivePreference(enabled: Bool) {
        liveCheckbox.state = enabled ? .on : .off
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func liveClicked() { onToggleLive?(liveCheckbox.state == .on) }
    @objc private func liveRevealClicked() {
        liveRevealedAfterStop.toggle()
        showLiveText(liveRevealedAfterStop)
    }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func showRecordingsClicked() { onShowRecordings?() }
}
