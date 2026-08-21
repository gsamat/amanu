import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance, and carries the menu that is amanu's fullest control surface.
///
/// The item can be taken away — `menu_bar_icon: false` — so it is held as an
/// optional and the menu is kept apart from it. That way the menu outlives
/// every removal: it is built once, the callbacks wired to it stay wired, and
/// putting the icon back is handing the same menu to a new status item rather
/// than rebuilding a second one that would have to be kept in step with the
/// first.
@MainActor
final class MenuBarController {
    enum State: Equatable {
        case idle
        case recording
        case paused
    }

    private let menu: NSMenu
    /// Nil while the icon is switched off.
    private var statusItem: NSStatusItem?
    /// What the icon would be showing if it were here, so that one put back
    /// mid-meeting shows the meeting rather than an idle feather.
    private var state: State = .idle
    private var elapsed: String?
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let autoRecordStatus: NSMenuItem
    private let updatesItem: NSMenuItem
    private let setupItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleAutoRecord: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onShowRecordings: (() -> Void)?
    var onShowWindow: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowSetup: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    init(visible: Bool = true) {
        menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(
            title: localised("idle", "не записывает"), action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: localised("Start recording", "Начать запись"),
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        pauseItem = NSMenuItem(
            title: localised("Pause", "Пауза"),
            action: #selector(pauseClicked),
            keyEquivalent: "p"
        )
        pauseItem.isEnabled = false
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        autoRecordItem = NSMenuItem(
            title: localised("Record meetings automatically", "Записывать встречи сама"),
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
            title: localised("Show Amanu window", "Показать окно amanu"),
            action: #selector(showWindowClicked),
            keyEquivalent: "w"
        )
        menu.addItem(showWindow)

        let openFolder = NSMenuItem(
            title: localised("Open recordings folder", "Открыть папку записей"),
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        // Not "r" — that starts a recording, and a shortcut that either starts
        // recording or opens a list depending on which item claimed it first
        // is worse than no shortcut.
        let recordings = NSMenuItem(
            title: localised("Manage recordings…", "Управление записями…"),
            action: #selector(showRecordingsClicked),
            keyEquivalent: "l"
        )
        menu.addItem(recordings)

        let settings = NSMenuItem(
            title: localised("Settings…", "Настройки…"),
            action: #selector(showSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(settings)

        // Hidden once the first run is over — see `setupAvailable`.
        setupItem = NSMenuItem(
            title: localised("Setup…", "Первая настройка…"),
            action: #selector(showSetupClicked),
            keyEquivalent: ""
        )
        menu.addItem(setupItem)

        // Hidden until someone says there is an updater behind it. A bare
        // build has nothing to update, and an item that can only report
        // failure is worse than no item.
        updatesItem = NSMenuItem(
            title: localised("Check for updates…", "Проверить обновления…"),
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        updatesItem.isHidden = true
        menu.addItem(updatesItem)

        // Where every Mac keeps it, near the bottom rather than at the top:
        // the application menu is the one place About is expected to be
        // first, and an `.accessory` app's application menu is only on
        // screen while one of its windows is in front.
        let about = NSMenuItem(
            title: localised("About Amanu", "О программе amanu"),
            action: #selector(showAboutClicked),
            keyEquivalent: ""
        )
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: localised("Quit Amanu", "Завершить amanu"),
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [
            toggleItem, pauseItem, autoRecordItem, showWindow, openFolder,
            recordings, settings, setupItem, updatesItem, about, quit,
        ] {
            item.target = self
        }

        update(state: .idle, elapsed: nil)
        setVisible(visible)
    }

    /// Put the icon in the menu bar, or take it away.
    ///
    /// Removal is real rather than a zero-width item: a status item with no
    /// width still occupies its slot, still opens its menu when the place it
    /// used to be is clicked, and still counts against the room the menu bar
    /// has — so a person who turned the icon off would keep bumping into it.
    func setVisible(_ visible: Bool) {
        guard visible != (statusItem != nil) else { return }
        if visible {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            item.button?.imagePosition = .imageLeft
            statusItem = item
            update(state: state, elapsed: elapsed)
        } else {
            statusItem.map(NSStatusBar.system.removeStatusItem)
            statusItem = nil
        }
    }

    /// Whether the icon is currently in the menu bar.
    var isVisible: Bool { statusItem != nil }

    /// Show or hide **Check for updates…**. Only a real application bundle
    /// can be replaced by Sparkle, so only a real application bundle offers it.
    func updatesAvailable(_ available: Bool) {
        updatesItem.isHidden = !available
    }

    /// Show or hide **Setup…**. The wizard is the first run, and once it has
    /// been through, the same form is in Settings for good — what the wizard
    /// adds is the order things must happen in and the line saying what is
    /// still outstanding, and both are answered by then. `amanu setup` resets
    /// the marker, so the item comes back whenever there is a first run to
    /// finish again.
    func setupAvailable(_ available: Bool) {
        setupItem.isHidden = !available
    }

    /// The items a person would actually see. Two of them come and go, and
    /// this is how anything outside asks which are on offer.
    var offeredItemTitles: [String] {
        menu.items.filter { !$0.isHidden }.map(\.title)
    }

    /// What the item says beside its icon in the menu bar, which is words as
    /// well as a clock — "paused" is in there, and it is the one string in
    /// this class that is not in the menu at all.
    var statusItemTitle: String { statusItem?.button?.title ?? "" }

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
        // Remembered whether or not there is an icon to draw it on: the menu
        // says the same things the icon does, and both are wanted the moment
        // the icon comes back.
        self.state = state
        self.elapsed = elapsed
        switch state {
        case .idle:
            stateLabel.title = localised("idle", "не записывает")
            toggleItem.title = localised("Start recording", "Начать запись")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = false
            statusItem?.button?.image = Self.icon(color: nil)
            statusItem?.button?.title = ""
        case .recording:
            stateLabel.title = localised("● recording · ", "● запись · ") + (elapsed ?? "0:00")
            toggleItem.title = localised("Stop recording", "Остановить запись")
            pauseItem.title = localised("Pause", "Пауза")
            pauseItem.isEnabled = true
            statusItem?.button?.image = Self.icon(color: .systemRed)
            // The elapsed time next to the icon is the difference between
            // "something is recording" and "I know it's recording" at a glance.
            statusItem?.button?.title = " \(elapsed ?? "0:00")"
        case .paused:
            stateLabel.title = localised("❙❙ paused · ", "❙❙ пауза · ") + (elapsed ?? "0:00")
            toggleItem.title = localised("Stop recording", "Остановить запись")
            pauseItem.title = localised("Resume", "Продолжить")
            pauseItem.isEnabled = true
            statusItem?.button?.image = Self.icon(color: .systemOrange)
            statusItem?.button?.title =
                " " + (elapsed ?? "0:00") + localised(" paused", " пауза")
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
    @objc private func showSetupClicked() { onShowSetup?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func showRecordingsClicked() { onShowRecordings?() }
    @objc private func checkForUpdatesClicked() { onCheckForUpdates?() }
    @objc private func showAboutClicked() { onShowAbout?() }
    @objc private func quitClicked() { onQuit?() }
}
