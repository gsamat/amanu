import AppKit
import Foundation

/// Turns a copy opened straight from the release image into an installed app.
///
/// A compressed DMG is read-only. Running there works for one session, but a
/// login item points at a volume that disappears when the image is ejected and
/// Sparkle cannot replace the bundle. Ask before either of those promises is
/// made, copy completely, then launch the installed copy through
/// LaunchServices so macOS continues attributing permissions to Amanu.
enum ApplicationRelocation {
    static func shouldOfferMove(bundleURL: URL?, volumeIsReadOnly: Bool) -> Bool {
        guard let bundleURL, bundleURL.pathExtension == "app" else { return false }
        return volumeIsReadOnly
    }

    static func supportsPersistentFeatures(
        bundleURL: URL?, volumeIsReadOnly: Bool
    ) -> Bool {
        guard let bundleURL, bundleURL.pathExtension == "app" else { return false }
        return !volumeIsReadOnly
    }

    static func volumeIsReadOnly(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Copy through a sibling first. If an older Amanu is already installed,
    /// `replaceItemAt` swaps it only after the complete new bundle exists, so
    /// an interrupted copy never leaves half an application in /Applications.
    static func install(
        from source: URL,
        in applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = applications.appendingPathComponent(
            source.lastPathComponent, isDirectory: true)
        let staging = applications.appendingPathComponent(
            ".\(source.deletingPathExtension().lastPathComponent).installing-\(UUID().uuidString).app",
            isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    /// Returns true after launching the installed copy, which tells `Run` to
    /// leave before it creates windows, login items, or an updater on the DMG.
    @MainActor
    static func offerMoveIfNeeded(bundleURL: URL? = Runtime.bundleURL) -> Bool {
        guard let bundleURL,
              shouldOfferMove(
                bundleURL: bundleURL,
                volumeIsReadOnly: volumeIsReadOnly(at: bundleURL)) else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = localised(
            "Move Amanu to Applications?",
            "Переместить Amanu в «Программы»?")
        alert.informativeText = localised(
            "Amanu is running from the disk image. Move it first so Start at Login and automatic updates keep working after the image is ejected.",
            "Amanu запущена с образа диска. Сначала переместите её, чтобы автозапуск и автообновления работали после извлечения образа.")
        alert.addButton(withTitle: localised(
            "Move to Applications", "Переместить в «Программы»"))
        alert.addButton(withTitle: localised("Not Now", "Не сейчас"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            let installed = try install(from: bundleURL)
            guard launch(installed) else {
                throw NSError(
                    domain: "me.samat.amanu.install",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: localised(
                        "The installed copy could not be opened.",
                        "Не удалось запустить установленую копию.")])
            }
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = localised(
                "Amanu couldn't be moved", "Не удалось переместить Amanu")
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: "OK")
            failure.runModal()
            return false
        }
    }

    @MainActor
    private static func launch(_ application: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        final class Answer: @unchecked Sendable {
            var launched = false
        }
        let answer = Answer()
        let finished = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) {
            app, _ in
            answer.launched = app != nil
            finished.signal()
        }
        guard finished.wait(timeout: .now() + 20) == .success else { return false }
        return answer.launched
    }
}
