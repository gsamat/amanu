import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self],
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

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        // .regular puts quill in the Dock and in ⌘-Tab. That's the point: the
        // menu bar is not a dependable place for the only control surface of a
        // recorder — when it fills up macOS parks the status item off-screen
        // and it stays clickable but invisible. The Dock can't be crowded out.
        app.setActivationPolicy(Config.dockIcon() ? .regular : .accessory)
        app.applicationIconImage = FeatherIcon.image(size: 512, color: nil)

        let controller = AppController(root: root)

        // NSApp holds its delegate weakly, and a Dock icon is useless if
        // clicking it does nothing.
        let delegate = AppDelegate()
        delegate.onReopen = { MainActor.assumeIsolated { controller.showWindow() } }
        delegate.onTerminate = { MainActor.assumeIsolated { controller.finishForTermination() } }
        app.delegate = delegate
        app.mainMenu = Self.mainMenu()

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        // Logout, restart, `launchctl kickstart -k`, `quill install
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

        // Start/stop from a hotkey tool: kill -USR1 $(pgrep -x quill)
        let sigusr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        sigusr1.setEventHandler {
            MainActor.assumeIsolated { controller.toggleRecording() }
        }
        sigusr1.resume()
        signal(SIGUSR1, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
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
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Quit routes through terminate so applicationWillTerminate runs and
        // a live recording is closed properly rather than truncated.
        appMenu.addItem(withTitle: "Quit quill", action: #selector(NSApplication.terminate(_:)),
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
/// how the window comes back after you close it; and quill must not quit just
/// because its only window was closed — it's a recorder, the window is a view
/// onto it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onReopen: (() -> Void)?
    var onTerminate: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        onReopen?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
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
    private let transcription = TranscriptionCoordinator()
    private let calendar: CalendarWatcher?
    private let autoRecord: AutoRecordController
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root

        let settings = Config.autoRecord()
        calendar = settings.calendar ? CalendarWatcher() : nil
        autoRecord = AutoRecordController(settings: settings, calendar: calendar)

        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onTogglePause = { [weak self] in self?.togglePause() }
        menuBar.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onShowWindow = { [weak self] in self?.showWindow() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(state: .idle, elapsed: nil)

        window.onToggle = { [weak self] in self?.toggle() }
        window.onTogglePause = { [weak self] in self?.togglePause() }
        window.onToggleAutoRecord = { [weak self] in self?.toggleAutoRecord() }
        window.onOpenFolder = { [weak self] in self?.openFolder() }
        if Config.showWindowAtLaunch() { window.show() }

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

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }

        if settings.enabled {
            Task { [weak self] in
                // The permission prompt only appears when the calendar trigger
                // is on, and it must land before the loop starts asking.
                await self?.calendar?.requestAccess()
                self?.autoRecord.start()
            }
        }
        menuBar.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)
        window.updateAutoRecord(enabled: autoRecord.enabled, decision: nil)

        // Runs for the life of the daemon, not just while recording: the menu
        // also shows what the auto-record loop is thinking, and a status line
        // that only updates during a recording is worse than none.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Start or stop by signal — `kill -USR1 $(pgrep -x quill)` — so a hotkey
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
        return MeetingContext(meeting: calendar?.bestMatch(for: Date()), app: mic.names.first)
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
                    title: "quill — recording started",
                    body: context.folderSuffix ?? newSession.dir.lastPathComponent
                )
            }
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
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
        // but only ever for recordings we started ourselves.
        let minimum = Config.autoRecord().minDuration
        if session.trigger != .manual, duration < minimum {
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

    /// Bring the status window up — from the Dock icon, the menu, or a second
    /// launch of an already-running quill.
    func showWindow() { window.show() }

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

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
