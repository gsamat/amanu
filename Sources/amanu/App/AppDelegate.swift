import AppKit

/// Dock behaviour. Clicking the icon of a running app sends a reopen, which is
/// how the window comes back after you close it; and amanu must not quit just
/// because its only window was closed — it's a recorder, the window is a view
/// onto it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called on a Dock click, with `alreadyActive` false when that click was
    /// the one that brought amanu forward.
    var onReopen: ((_ alreadyActive: Bool) -> Void)?
    var onTerminate: (() -> Void)?
    /// Gives asynchronous filesystem work a chance to cancel and remove its
    /// unpublished staging folder before the process exits. Returning true
    /// means the callback will answer AppKit's deferred termination request.
    var onPrepareTermination: ((_ completion: @escaping () -> Void) -> Bool)?
    var onReviewQuit: (@MainActor () async -> Bool)?
    /// The app menu's Settings item hangs off the delegate because it is the
    /// only NSObject in the picture — AppController is a plain class, and a
    /// menu item needs a target it can send a selector to.
    var onShowSettings: (() -> Void)?
    var onShowSetup: (() -> Void)?
    var onImport: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onShowAbout: (() -> Void)?
    /// Answers whether ⌘Q needs to ask first. The default gate knows of no
    /// recording, which is the right answer for a delegate nobody wired up.
    var quitGate = QuitGate()

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

    /// Quitting a recorder mid-meeting is not an ordinary quit. What survives
    /// is the part people assume is at risk — `applicationWillTerminate` closes
    /// the session properly and it is transcribed like any other — and what is
    /// lost is the part nobody thinks about: everything said between this quit
    /// and the next launch, which cannot be recovered from anywhere. So the
    /// alert leads with the elapsed time and then says exactly that (.issues/005,
    /// where a quit during a call cost three minutes of it).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .ask(let elapsed) = quitGate.decide() {
            let running = AppController.format(elapsed)
            let alert = NSAlert()
            alert.messageText = localised(
                "Quit while a recording is running? It has been going for \(running).",
                "Выйти во время записи? Она идёт уже \(running).")
            alert.informativeText = localised(
                """
                Quitting stops the recording and saves it — nothing recorded so far is lost, \
                and it will be transcribed like any other session. But nothing is recorded \
                after this until amanu runs again.
                """,
                """
                При выходе запись остановится и сохранится — записанное не пропадёт \
                и будет расшифровано, как любая другая сессия. Но дальше, до следующего \
                запуска amanu, ничего записываться не будет.
                """)
            alert.addButton(withTitle: localised(
                "Quit and save the recording", "Выйти и сохранить запись"))
            alert.addButton(withTitle: localised("Keep recording", "Продолжить запись"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }

        if let onReviewQuit {
            Task { @MainActor in
                guard await onReviewQuit() else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                let deferred = onPrepareTermination? {
                    sender.reply(toApplicationShouldTerminate: true)
                } ?? false
                if !deferred { sender.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        }

        let deferred = onPrepareTermination? {
            sender.reply(toApplicationShouldTerminate: true)
        } ?? false
        return deferred ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
        Analytics.flushOnExit()
    }

    /// The app menu's **Setup…**, kept so that it can be taken away once the
    /// first run is over and put back when `amanu setup` asks for it again.
    var setupItem: NSMenuItem?

    func setupAvailable(_ available: Bool) {
        setupItem?.isHidden = !available
    }

    @objc func showSettingsClicked(_ sender: Any?) { onShowSettings?() }
    @objc func showSetupClicked(_ sender: Any?) { onShowSetup?() }
    @objc func importClicked(_ sender: Any?) { onImport?() }
    @objc func checkForUpdatesClicked(_ sender: Any?) { onCheckForUpdates?() }
    @objc func showAboutClicked(_ sender: Any?) { onShowAbout?() }
}
