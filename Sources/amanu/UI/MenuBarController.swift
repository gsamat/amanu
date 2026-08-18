import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let autoRecordStatus: NSMenuItem

    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        pauseItem = NSMenuItem(
            title: "Pause",
            action: #selector(pauseClicked),
            keyEquivalent: "p"
        )
        pauseItem.isEnabled = false
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        autoRecordItem = NSMenuItem(
            title: "Record meetings automatically",
            action: #selector(autoRecordClicked),
            keyEquivalent: ""
        )
        menu.addItem(autoRecordItem)

        // What the auto-record loop is currently thinking. Without this the
        // only way to answer "why didn't it record that call" is a debugger.
        autoRecordStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        autoRecordStatus.isEnabled = false
        autoRecordStatus.isHidden = true
        menu.addItem(autoRecordStatus)

        menu.addItem(.separator())

        // The window is the reliable surface — this item is how you get it
        // back when the menu bar is where you happened to look first.
        let showWindow = NSMenuItem(
            title: "Show Amanu window",
            action: #selector(showWindowClicked),
            keyEquivalent: "w"
        )
        menu.addItem(showWindow)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Amanu",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, pauseItem, autoRecordItem, showWindow, openFolder, settings, quit] {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeft
        update(state: .idle, elapsed: nil)
    }

    /// Reflect recording state in the icon and the menu. Called once a second
    /// while recording.
    ///
    /// The icon is redrawn rather than tinted. A template image asks the system
    /// to render it in the menu bar's own foreground colour, and
    /// `contentTintColor` doesn't reliably win that argument — over a dark
    /// wallpaper the "red" feather comes out near-black on near-black and the
    /// icon effectively vanishes while recording, which is the one state that
    /// must never be invisible (upstream issue #15). Drawing the colour into a
    /// non-template image takes the system out of the decision.
    func update(state: State, elapsed: String?) {
        switch state {
        case .idle:
            stateLabel.title = "idle"
            toggleItem.title = "Start recording"
            pauseItem.title = "Pause"
            pauseItem.isEnabled = false
            statusItem.button?.image = Self.icon(color: nil)
            statusItem.button?.title = ""
        case .recording:
            stateLabel.title = "● recording · \(elapsed ?? "0:00")"
            toggleItem.title = "Stop recording"
            pauseItem.title = "Pause"
            pauseItem.isEnabled = true
            statusItem.button?.image = Self.icon(color: .systemRed)
            // The elapsed time next to the icon is the difference between
            // "something is recording" and "I know it's recording" at a glance.
            statusItem.button?.title = " \(elapsed ?? "0:00")"
        case .paused:
            stateLabel.title = "❙❙ paused · \(elapsed ?? "0:00")"
            toggleItem.title = "Stop recording"
            pauseItem.title = "Resume"
            pauseItem.isEnabled = true
            statusItem.button?.image = Self.icon(color: .systemOrange)
            statusItem.button?.title = " \(elapsed ?? "0:00") paused"
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Reflect the auto-record switch and the reason behind its current
    /// decision.
    func updateAutoRecord(enabled: Bool, decision: String?) {
        autoRecordItem.state = enabled ? .on : .off
        autoRecordStatus.title = decision.map { "   \($0)" } ?? ""
        autoRecordStatus.isHidden = !enabled || decision == nil
    }

    /// Menu-bar status icons are nominally 18pt tall; 16 leaves a little air.
    private static func icon(color: NSColor?) -> NSImage? {
        FeatherIcon.image(size: 16, color: color)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func autoRecordClicked() { onToggleAutoRecord?() }
    @objc private func showWindowClicked() { onShowWindow?() }
    @objc private func showSettingsClicked() { onShowSettings?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
