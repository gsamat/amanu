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
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

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
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(state: .idle, elapsed: nil)

        autoRecord.currentSession = { [weak self] in self?.session }
        autoRecord.startRecording = { [weak self] trigger, title in
            self?.startSession(trigger: trigger, title: title)
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
        stopSession(reason: "app-quit")
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            autoRecord.noteManualStart()
            startSession(trigger: .manual, title: calendar?.bestMatch(for: Date())?.title)
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
        menuBar.updateAutoRecord(
            enabled: autoRecord.enabled,
            decision: autoRecord.enabled ? autoRecord.lastDecision : nil
        )
    }

    private func startSession(trigger: RecordingSession.Trigger, title: String?) {
        guard session == nil else { return }
        do {
            let newSession = try RecordingSession(root: root, title: title, trigger: trigger)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data(
                "● recording (\(trigger.rawValue)) → \(newSession.dir.path)\n".utf8
            ))
            if trigger != .manual {
                notifyUser(
                    title: "quill — recording started",
                    body: title ?? newSession.dir.lastPathComponent
                )
            }
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(state: .recording, elapsed: "0:00")
    }

    private func stopSession(reason: String = "manual") {
        guard let session else { return }
        session.stop(reason: reason)
        let duration = Date().timeIntervalSince(session.startedAt)
        FileHandle.standardError.write(Data(
            "○ stopped (\(reason)) · \(Self.format(duration)) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        menuBar.update(state: .idle, elapsed: nil)

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
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        menuBar.updateAutoRecord(
            enabled: autoRecord.enabled,
            decision: autoRecord.enabled ? autoRecord.lastDecision : nil
        )
        guard let session else { return }
        menuBar.update(
            state: session.isPaused ? .paused : .recording,
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
