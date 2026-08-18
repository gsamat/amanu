import Foundation

/// Best-effort user-visible notification. osascript keeps us free of
/// UserNotifications entitlement requirements (which need an app bundle).
func notifyUser(title: String, body: String) {
    // Tests exercise code paths that notify; nobody wants a banner per test.
    guard ProcessInfo.processInfo.environment["AMANU_NO_NOTIFY"] == nil else { return }
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    // A banner has no business anywhere on disk; give it an empty scratch
    // directory rather than whatever the daemon happens to be standing in.
    task.currentDirectoryURL = FileManager.default.temporaryDirectory
    try? task.run()
}
