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
///
/// The menu is read top to bottom as one story: what is happening (the status
/// lines), what to do about it (the recording controls), the switch that
/// decides whether it happens without being asked, the places amanu can be
/// opened from, about and settings, and the way out. The two start commands at
/// rest and the pause/stop pair during a meeting occupy those slots in place of
/// each other — only one state's worth of them is ever visible — which is what
/// keeps the meeting controls within one glance of the clock that describes
/// them.
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
    private let startItem: NSMenuItem
    private let startWithVideoItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let videoItem: NSMenuItem
    private let stopItem: NSMenuItem
    private let autoRecordItem: NSMenuItem
    private let autoRecordStatus: NSMenuItem
    private let updatesItem: NSMenuItem
    private let setupItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onStartWithVideo: (() -> Void)?
    var onToggleVideo: (() -> Void)?
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
        // The first line of the menu carries the same clock the icon does,
        // and it ticks while the menu is open. Setting the font on the menu
        // rather than on that one item is what keeps the rest of it alone:
        // an item drawn from an attributed title loses the grey the system
        // gives a disabled one, and the state line is disabled.
        menu.font = NSFont.menuFont(ofSize: 0).tabularFigures

        stateLabel = NSMenuItem(
            title: localised("idle", "не записывает"), action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        // Two ways in, side by side, because which one is wanted is decided at
        // the moment somebody is about to be in a call rather than in a
        // settings window an hour before it.
        startItem = NSMenuItem(
            title: localised("Start recording", "Начать запись"),
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(startItem)

        // Command-R belongs to the start/stop pair below and nowhere else: two
        // start commands competing for one shortcut would make the shortcut
        // mean whichever the system reached first.
        startWithVideoItem = NSMenuItem(
            title: localised("Start recording with video", "Начать запись с видео"),
            action: #selector(startWithVideoClicked),
            keyEquivalent: ""
        )
        menu.addItem(startWithVideoItem)

        pauseItem = NSMenuItem(
            title: localised("Pause recording", "Приостановить запись"),
            action: #selector(pauseClicked),
            keyEquivalent: "p"
        )
        pauseItem.isHidden = true
        menu.addItem(pauseItem)

        // Video is off unless asked for, so the way to ask is here, during a
        // meeting, where the decision actually gets made. Hidden while nothing
        // is recording — a way to start video with no recording to attach it
        // to is a button that can only do nothing — and hidden again once this
        // session has had its one video file.
        videoItem = NSMenuItem(
            title: localised("Record video", "Записать видео"),
            action: #selector(videoClicked),
            keyEquivalent: ""
        )
        videoItem.isHidden = true
        menu.addItem(videoItem)

        // The same Command-R as Start recording, which is deliberate: only one
        // of the two is ever visible, and both drive `onToggle`, so the
        // shortcut cannot do the wrong thing whichever one answers it.
        stopItem = NSMenuItem(
            title: localised("Stop recording", "Остановить запись"),
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        stopItem.isHidden = true
        menu.addItem(stopItem)

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

        let recordings = NSMenuItem(
            title: localised("Manage recordings…", "Управление записями…"),
            action: #selector(showRecordingsClicked),
            keyEquivalent: "l"
        )
        menu.addItem(recordings)

        menu.addItem(.separator())

        // About first, where every Mac puts it, then the two things that change
        // how amanu behaves. Import is not here: it is in the File menu of the
        // application menu, and in the window it belongs to, and a third copy
        // in a menu about recording was one door too many.
        let about = NSMenuItem(
            title: localised("About Amanu", "О программе amanu"),
            action: #selector(showAboutClicked),
            keyEquivalent: ""
        )
        menu.addItem(about)

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

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: localised("Quit Amanu", "Завершить amanu"),
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [
            startItem, startWithVideoItem, pauseItem, videoItem, stopItem,
            autoRecordItem, showWindow, openFolder,
            recordings, about, settings, setupItem, updatesItem, quit,
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
            // The clock ticks once a second, and in the menu bar font every
            // digit has its own width — so 1:19 becoming 1:20 changes the
            // length of the title and the whole item jitters sideways under
            // the eye. Asking the same font for its tabular figures sets the
            // numerals on one common advance and holds the item still; the
            // font itself is left alone, since the only thing wrong with it
            // was the spacing of ten glyphs.
            if let button = item.button, let font = button.font {
                button.font = font.tabularFigures
            }
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

    /// Drive one of the visible commands. Besides making the status menu
    /// inspectable without exposing its whole mutable NSMenu, this mirrors
    /// exactly what AppKit does when a person clicks the item.
    @discardableResult
    func performOfferedItem(titled title: String) -> Bool {
        guard let item = menu.items.first(where: { !$0.isHidden && $0.title == title }) else {
            return false
        }
        guard let action = item.action else { return false }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
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
    ///
    /// The two start commands and the pause/stop pair share the same slots: at
    /// rest the menu offers the ways in, and while a meeting is running it
    /// offers the ways through it.
    ///
    /// `videoActive` changes the words, not the clock: the first line says
    /// "recording with video" while the picture is being written, which is the
    /// question somebody opening this menu is actually asking.
    func update(state: State, elapsed: String?, videoActive: Bool = false) {
        // Remembered whether or not there is an icon to draw it on: the menu
        // says the same things the icon does, and both are wanted the moment
        // the icon comes back.
        self.state = state
        self.elapsed = elapsed
        let running = state != .idle
        startItem.isHidden = running
        startWithVideoItem.isHidden = running
        pauseItem.isHidden = !running
        stopItem.isHidden = !running
        pauseItem.isEnabled = running
        switch state {
        case .idle:
            stateLabel.title = localised("idle", "не записывает")
            pauseItem.title = localised("Pause recording", "Приостановить запись")
            statusItem?.button?.image = Self.icon(color: nil)
            statusItem?.button?.title = ""
        case .recording:
            stateLabel.title = localised(
                videoActive ? "● recording with video · " : "● recording · ",
                videoActive ? "● запись с видео · " : "● запись · "
            ) + (elapsed ?? "0:00")
            pauseItem.title = localised("Pause recording", "Приостановить запись")
            statusItem?.button?.image = Self.icon(color: .systemRed)
            // The elapsed time next to the icon is the difference between
            // "something is recording" and "I know it's recording" at a glance.
            statusItem?.button?.title = " \(elapsed ?? "0:00")"
        case .paused:
            stateLabel.title = localised("❙❙ paused · ", "❙❙ пауза · ") + (elapsed ?? "0:00")
            pauseItem.title = localised("Resume recording", "Продолжить запись")
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

    /// Show the video item only while a recording can still gain or lose a
    /// video track, and say which way the next click goes.
    func updateVideo(visible: Bool, active: Bool) {
        videoItem.isHidden = !visible
        videoItem.title = active
            ? localised("Stop recording video", "Остановить запись видео")
            : localised("Record video", "Записать видео")
    }

    /// Menu-bar status icons are nominally 18pt tall; 16 leaves a little air.
    private static func icon(color: NSColor?) -> NSImage? {
        FeatherIcon.image(size: 16, color: color)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func pauseClicked() { onTogglePause?() }
    @objc private func startWithVideoClicked() { onStartWithVideo?() }
    @objc private func videoClicked() { onToggleVideo?() }
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
