import AppKit
import Foundation
import UserNotifications

/// Banners that belong to amanu.
///
/// The old ones didn't. `osascript -e 'display notification'` posts under
/// AppleScript's identity, so macOS drew them as Script Editor's, and clicking
/// one opened Script Editor — an app the person never asked for, showing
/// nothing about their meeting. It was the honest choice while amanu was a
/// bare binary, because `UNUserNotificationCenter` needs a bundle to belong to.
///
/// Inside `Amanu.app` there is one, so the banner says amanu, carries the
/// recording it is about, and clicking it opens that folder.
enum Notifications {
    /// The bundled path when there is a bundle, and the old trick when there
    /// isn't — the LaunchAgent copy still runs on machines mid-migration.
    static var usesNotificationCenter: Bool { Runtime.isBundled }

    private static let sessionKey = "me.samat.amanu.session"

    @MainActor
    private static var authorization: Task<Bool, Never>?
    @MainActor
    private static var delegate: Delegate?

    /// Called once at startup so a click has somewhere to go. `onOpen` is
    /// handed the session folder when the banner named one.
    @MainActor
    static func install(onOpen: @escaping @MainActor (URL?) -> Void) {
        guard usesNotificationCenter else { return }
        let delegate = Delegate(onOpen: onOpen)
        Self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    @MainActor
    static func post(title: String, body: String, opening session: URL?) {
        guard ProcessInfo.processInfo.environment["AMANU_NO_NOTIFY"] == nil else { return }
        guard usesNotificationCenter else {
            postThroughAppleScript(title: title, body: body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let session { content.userInfo = [sessionKey: session.path] }

        // Asked for once, lazily: a permission dialog on first launch, before
        // anything has happened, is a question about nothing.
        let request = authorization ?? Task { () -> Bool in
            (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorization = request

        Task {
            guard await request.value else { return }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// A banner has no business anywhere on disk; give it an empty scratch
    /// directory rather than whatever the daemon happens to be standing in.
    private static func postThroughAppleScript(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e", "display notification \(quoted(body)) with title \(quoted(title))",
        ]
        task.currentDirectoryURL = FileManager.default.temporaryDirectory
        try? task.run()
    }

    /// The folder a banner was about, or nil when it named none.
    static func session(in userInfo: [AnyHashable: Any]) -> URL? {
        (userInfo[sessionKey] as? String).map { URL(fileURLWithPath: $0) }
    }

    @MainActor
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        private let onOpen: @MainActor (URL?) -> Void

        init(onOpen: @escaping @MainActor (URL?) -> Void) {
            self.onOpen = onOpen
        }

        /// Show the banner even when amanu is the active app: the recording it
        /// announces finished in the background, and the window it would
        /// otherwise be hidden behind may be on another Space.
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let folder = Notifications.session(
                in: response.notification.request.content.userInfo)
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                onOpen(folder)
            }
        }
    }
}

/// Best-effort user-visible notification.
func notifyUser(title: String, body: String, opening session: URL? = nil) {
    guard ProcessInfo.processInfo.environment["AMANU_NO_NOTIFY"] == nil else { return }
    Task { @MainActor in
        Notifications.post(title: title, body: body, opening: session)
    }
}
