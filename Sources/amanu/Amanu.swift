import AppKit
import ArgumentParser
import Foundation

@main
struct Amanu: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amanu",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [
            Run.self, Setup.self, Doctor.self, Install.self, Sessions.self, ProcessSession.self,
        ],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // launchd starts us in `/`, and every process we spawn inherits that.
        // An agent CLI started at the root of the disk goes looking around it,
        // and macOS bills the privacy prompts it earns to us — we are the
        // responsible process for everything we launch. Sit in the recordings
        // folder instead, which is the only place we have business in.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(root.path)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            // A failed permission is exactly what the first-run window exists
            // to repair. `amanu setup` also resets this marker before launching,
            // so a denied grant can never make the repair UI unreachable.
            if !SetupState.isPending || !DoctorReport.canContinueIntoSetup(checks) {
                throw ExitCode(1)
            }
        }

        let app = NSApplication.shared
        // .regular puts amanu in the Dock and in ⌘-Tab. That's the point: the
        // menu bar is not a dependable place for the only control surface of a
        // recorder — when it fills up macOS parks the status item off-screen
        // and it stays clickable but invisible. The Dock can't be crowded out.
        app.setActivationPolicy(Config.dockIcon() ? .regular : .accessory)
        app.applicationIconImage = FeatherIcon.image(size: 512, color: nil)

        let controller = AppController(root: root)

        // NSApp holds its delegate weakly, and a Dock icon is useless if
        // clicking it does nothing.
        let delegate = AppDelegate()
        delegate.onReopen = { alreadyActive in
            MainActor.assumeIsolated { controller.toggleWindow(alreadyActive: alreadyActive) }
        }
        delegate.onTerminate = { MainActor.assumeIsolated { controller.finishForTermination() } }
        delegate.onShowSettings = { MainActor.assumeIsolated { controller.showSettings() } }
        delegate.onShowSetup = { MainActor.assumeIsolated { controller.showSetup() } }
        app.delegate = delegate
        app.mainMenu = Self.mainMenu(settingsTarget: delegate)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        // Logout, restart, `launchctl kickstart -k`, `amanu install
        // --uninstall` — all of them send SIGTERM, and the default action for
        // it kills us outright. That matters more than it looks: an AAC track
        // is unreadable until its packet table is written at close, so an
        // unhandled SIGTERM mid-meeting doesn't lose the last few seconds, it
        // loses the whole recording. Handling it turns a reboot into a clean
        // stop with a finished file and a meta.json.
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler {
            FileHandle.standardError.write(Data("\nSIGTERM — finalizing\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigterm.resume()
        signal(SIGTERM, SIG_IGN)

        // Start/stop from a hotkey tool: kill -USR1 $(pgrep -x amanu)
        let sigusr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sigusr1.setEventHandler {
            MainActor.assumeIsolated { controller.toggleRecording() }
        }
        sigusr1.resume()
        signal(SIGUSR1, SIG_IGN)

        FileHandle.standardError.write(Data(
            "amanu up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
        // Retained until the run loop exits: NSApp's delegate reference is
        // weak, and a deallocated one silently stops handling Dock clicks.
        withExtendedLifetime(delegate) {}
    }

    /// A .regular app owns the menu bar while it's focused, and without a main
    /// menu that bar is empty — no ⌘Q, no window menu. This is the minimum
    /// that makes the app behave like an app.
    @MainActor
    private static func mainMenu(settingsTarget: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⌘, is where every Mac user looks for settings, and it only works
        // from the main menu — the status item's copy of it is live just
        // while that menu is open.
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(AppDelegate.showSettingsClicked(_:)),
            keyEquivalent: ","
        )
        settings.target = settingsTarget
        appMenu.addItem(settings)
        let setup = NSMenuItem(
            title: "Setup…",
            action: #selector(AppDelegate.showSetupClicked(_:)),
            keyEquivalent: ""
        )
        setup.target = settingsTarget
        appMenu.addItem(setup)
        appMenu.addItem(.separator())
        // Quit routes through terminate so applicationWillTerminate runs and
        // a live recording is closed properly rather than truncated.
        appMenu.addItem(withTitle: "Quit Amanu", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}

/// Dock behaviour. Clicking the icon of a running app sends a reopen, which is
/// how the window comes back after you close it; and amanu must not quit just
/// because its only window was closed — it's a recorder, the window is a view
/// onto it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called on a Dock click, with `alreadyActive` false when that click was
    /// the one that brought amanu forward.
    var onReopen: ((_ alreadyActive: Bool) -> Void)?
    var onTerminate: (() -> Void)?
    /// The app menu's Settings item hangs off the delegate because it is the
    /// only NSObject in the picture — AppController is a plain class, and a
    /// menu item needs a target it can send a selector to.
    var onShowSettings: (() -> Void)?
    var onShowSetup: (() -> Void)?

    private var becameActiveAt = Date.distantPast

    func applicationDidBecomeActive(_ notification: Notification) {
        becameActiveAt = Date()
    }

    /// Clicking the Dock icon of an app that's already in front should put the
    /// window away again — show, hide, show. The catch is that AppKit
    /// activates the app *before* asking us, so `NSApp.isActive` is true
    /// either way; the only thing that separates "already working in amanu"
    /// from "just switched to it" is how long ago activation happened.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let justActivated = Date().timeIntervalSince(becameActiveAt) < 0.3
        onReopen?(!justActivated)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }

    @objc func showSettingsClicked(_ sender: Any?) { onShowSettings?() }
    @objc func showSetupClicked(_ sender: Any?) { onShowSetup?() }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let window = StatusWindow()
    /// Built on first use. It is thirty-odd controls, and amanu spends nearly
    /// all of its life recording rather than being configured.
    private lazy var settings = SettingsWindow()
    private lazy var setupWindow: SetupWindow = {
        let setup = SetupWindow()
        setup.isRecording = { [weak self] in self?.session != nil }
        setup.onFinished = { [weak self] in
            self?.startAutomaticFeatures(requestCalendarAccess: false)
        }
        return setup
    }()
    private let transcription = TranscriptionCoordinator()
    private let calendar: CalendarWatcher?
    private let autoRecord: AutoRecordController
    private var session: RecordingSession?
    private var ticker: Timer?
    private lazy var recordings = RecordingsWindow(root: root)
    private var network: NetworkMonitor?
    private var setupRequestObserver: NSObjectProtocol?
    private var automaticFeaturesStarted = false

    init(root: URL) {
        self.root = root

        let settings = Config.autoRecord()
        // The calendar is worth reading for names even when it isn't a
        // trigger: "Integration sync (zoom.us)" beats "20:39" in a folder list
        // whether or not the event is what started the recording.
        calendar = (Config.useCalendar() || settings.calendar) ? CalendarWatcher() : nil
        autoRecord = AutoRecordController(settings: settings, calendar: calendar)

        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onShowRecordings = { [weak self] in self?.showRecordings() }
        menuBar.onShowWindow = { [weak self] in self?.showWindow() }
        menuBar.onShowSettings = { [weak self] in self?.showSettings() }
        menuBar.onShowSetup = { [weak self] in self?.showSetup() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(state: .idle, elapsed: nil)

        window.onToggle = { [weak self] in self?.toggle() }
        window.onTogglePause = { [weak self] in self?.togglePause() }
        window.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        window.onOpenFolder = { [weak self] in self?.openFolder() }
        window.onShowRecordings = { [weak self] in self?.showRecordings() }
        if Config.showWindowAtLaunch(), !SetupState.isPending { window.show() }

        autoRecord.currentSession = { [weak self] in self?.session }
        autoRecord.startRecording = { [weak self] trigger, context in
            self?.startSession(trigger: trigger, context: context)
        }
        autoRecord.stopRecording = { [weak self] reason in
            self?.stopSession(reason: reason)
        }

        // Adopt anything a crash left behind *before* the queue scans, so a
        // rescued session is transcribed in the same pass as the clean ones.
        RecordingSession.recoverInterrupted(root: root)

        menuBar.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)

        // Runs for the life of the daemon, not just while recording: the menu
        // also shows what the auto-record loop is thinking, and a status line
        // that only updates during a recording is worse than none.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        setupRequestObserver = SetupRequest.observe { [weak self] in self?.showSetup() }
        if SetupState.isPending {
            showSetup()
        } else {
            startAutomaticFeatures(requestCalendarAccess: true)
        }
    }

    /// Start the background behavior only after the first-run decision. The
    /// setup window owns its prompts; starting the calendar watcher behind it
    /// would make "Later" immediately raise the prompt it just postponed.
    private func startAutomaticFeatures(requestCalendarAccess: Bool) {
        guard !automaticFeaturesStarted else { return }
        automaticFeaturesStarted = true

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
            // After the queue, not before: a session that transcribes in this
            // pass gets named and summarized by the coordinator itself, and
            // the sweep is only for what was left over from earlier runs.
            await PostProcessor.sweep(root: root)
        }

        // A backlog deferred for want of a model is only half-solved by
        // recording the fact — something has to come back for it when the
        // network does.
        let monitor = NetworkMonitor { [root] in
            Task { await PostProcessor.sweep(root: root) }
        }
        monitor.start()
        network = monitor

        autoRecord.enabled = Config.autoRecord().enabled
        let shouldStart = autoRecord.enabled
        Task { [weak self] in
            if requestCalendarAccess { await self?.calendar?.requestAccess() }
            if shouldStart { self?.autoRecord.start() }
        }
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)
    }

    /// Start or stop by signal — `kill -USR1 $(pgrep -x amanu)` — so a hotkey
    /// tool can drive recording without going through the menu.
    func toggleRecording() { toggle() }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        finishForTermination()
        NSApp.terminate(nil)
    }

    /// Close a live recording without exiting — the half of shutdown that has
    /// to happen when the quit came from ⌘Q or the Dock rather than from us.
    /// Idempotent: stopSession does nothing without a session.
    func finishForTermination() {
        stopSession(reason: "app-quit")
    }

    private func toggle() {
        if session == nil {
            autoRecord.noteManualStart()
            startSession(trigger: .manual, context: currentContext())
        } else {
            autoRecord.noteManualStop()
            stopSession(reason: "manual")
        }
    }

    private func togglePause() {
        guard let session else { return }
        if session.isPaused {
            session.resume()
        } else {
            session.pause()
        }
        tick()
    }

    private func toggleAutoRecord() {
        autoRecord.enabled.toggle()
        if autoRecord.enabled { autoRecord.start() } else { autoRecord.stop() }
        let decision = autoRecord.enabled ? autoRecord.lastDecision : nil
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
    }

    /// What we can tell about a meeting being started by hand: whichever call
    /// app is already holding the microphone, plus the calendar's view of now.
    private func currentContext() -> MeetingContext {
        let settings = Config.autoRecord()
        let mic = MicActivityMonitor.check(
            callApps: settings.callApps, ignoring: settings.ignoreApps
        )
        return MeetingContext(
            meeting: calendar?.bestMatch(for: Date()),
            app: mic.names.first,
            appFamilies: mic.families
        )
    }

    private func startSession(trigger: RecordingSession.Trigger, context: MeetingContext) {
        guard session == nil else { return }
        do {
            let newSession = try RecordingSession(root: root, context: context, trigger: trigger)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data(
                "● recording (\(trigger.rawValue)) → \(newSession.dir.path)\n".utf8
            ))
            if trigger != .manual {
                notifyUser(
                    title: "amanu — recording started",
                    body: context.folderSuffix ?? newSession.dir.lastPathComponent
                )
            }
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "amanu — recording failed", body: "\(error)")
            return
        }

        present(.recording, elapsed: "0:00")
    }

    private func stopSession(reason: String = "manual") {
        guard let session else { return }
        session.stop(reason: reason)
        let duration = Date().timeIntervalSince(session.startedAt)
        FileHandle.standardError.write(Data(
            "○ stopped (\(reason)) · \(Self.format(duration)) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        present(.idle, elapsed: nil)

        // A mic that opened for a few seconds was never a meeting. Throwing
        // these away is what keeps the recordings folder worth opening —
        // but only ever for recordings we started ourselves, and only when the
        // recording ended because the meeting did.
        //
        // "app-quit" and "max-duration" say nothing about whether this was a
        // real meeting: they mean we stopped it. Discarding on those threw
        // away the first fifteen seconds of a genuine call that happened to
        // start while amanu was being reinstalled (2026.08.18).
        let endedByItself = ["call-ended", "silence", "calendar-event-ended"].contains(reason)
        let minimum = Config.autoRecord().minDuration
        if session.trigger != .manual, endedByItself, duration < minimum {
            FileHandle.standardError.write(Data(
                ("discarded \(session.dir.lastPathComponent): \(Int(duration))s "
                    + "is under the \(Int(minimum))s minimum for an automatic recording\n").utf8
            ))
            session.discard()
            return
        }

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        let text: String?
        switch status {
        case .idle:
            text = nil
        case .transcribing(let name, let queued):
            text = queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
        case .failed(let name):
            text = "transcription failed · \(name)"
        }
        menuBar.updateTranscription(text)
        window.updateTranscription(text)
    }

    /// Bring the status window up — from the menu, or a second launch of an
    /// already-running amanu.
    func showWindow() { window.show() }

    /// Settings, from either menu. Activating first because a click on the
    /// status item doesn't bring the app forward, and a settings window you
    /// have to click again before you can type in it is a small insult.
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        settings.show()
    }

    /// First-run setup, reopened from either menu or `amanu setup`.
    func showSetup() {
        NSApp.activate(ignoringOtherApps: true)
        setupWindow.show()
    }

    /// The Dock icon: show the window, or put it away if amanu was already in
    /// front and it's sitting there.
    func toggleWindow(alreadyActive: Bool) {
        if alreadyActive, window.isVisible {
            window.hide()
        } else {
            window.show()
        }
    }

    /// Reflect state everywhere it's shown at once, so the three surfaces can
    /// never disagree about whether something is being recorded.
    private func present(_ state: MenuBarController.State, elapsed: String?) {
        menuBar.update(state: state, elapsed: elapsed)
        window.update(state: state, elapsed: elapsed)
        // The Dock tile is the one indicator nothing can hide or crowd out.
        NSApp.applicationIconImage = FeatherIcon.image(
            size: 512,
            color: FeatherIcon.color(recording: state != .idle, paused: state == .paused)
        )
        NSApp.dockTile.badgeLabel = state == .idle ? nil : elapsed
    }

    private func tick() {
        let decision = autoRecord.enabled ? autoRecord.lastDecision : nil
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: decision)
        guard let session else { return }
        present(
            session.isPaused ? .paused : .recording,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private func showRecordings() {
        // A session put back in the queue should start transcribing now, not
        // at the next launch — the person asking for it is watching.
        recordings.onRetranscribe = { [transcription, root] _ in
            Task { await transcription.resumePending(root: root) }
        }
        NSApp.activate(ignoringOtherApps: true)
        recordings.show()
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
