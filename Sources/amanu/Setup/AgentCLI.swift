import Foundation

/// `~/.local/bin/amanu`, kept pointing at the executable inside the bundle.
///
/// Agents and scripts call amanu by name, and the command line has to be the
/// same signed program as the app — otherwise it isn't talking to the copy
/// that holds the microphone. A symlink into the installed bundle gives both
/// for free, and an application update updates the command line with it. A
/// bundle on a DMG is deliberately excluded: the symlink would break as soon
/// as the image was ejected.
enum AgentCLI {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/amanu")

    /// Homebrew's standard prefixes. Finder launches do not inherit the shell's
    /// PATH, so the app cannot ask `command -v`; these are the two locations a
    /// supported macOS Homebrew installation uses on Apple Silicon and Intel.
    static let managedCLIs = [
        URL(fileURLWithPath: "/opt/homebrew/bin/amanu"),
        URL(fileURLWithPath: "/usr/local/bin/amanu"),
    ]

    /// Called at startup. Returns true when it changed something, so the app
    /// can say so once rather than every launch.
    @discardableResult
    static func install(
        at cli: URL = path,
        to executable: URL = Runtime.executableURL,
        managedCLIs: [URL] = managedCLIs,
        persistent: Bool = Runtime.supportsPersistentFeatures,
        now: Date = Date()
    ) -> Result<Bool, Error> {
        guard persistent else { return .success(false) }
        let target = executable.resolvingSymlinksInPath()
        guard !managedCLIs.contains(where: {
            $0.resolvingSymlinksInPath() == target
        }) else { return .success(false) }
        return link(at: cli, to: executable, now: now)
    }

    /// An existing symlink is replaced — it is a pointer, not anybody's file.
    /// A real binary is moved aside with the date rather than overwritten, and
    /// if that name is taken the backup is numbered instead of failing.
    static func link(at cli: URL, to executable: URL, now: Date) -> Result<Bool, Error> {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: cli.path) {
            guard existing != executable.path else { return .success(false) }
            do { try fm.removeItem(at: cli) } catch { return .failure(error) }
        } else if fm.fileExists(atPath: cli.path) {
            var backup = cli.appendingPathExtension("legacy-\(stamp(now))")
            var attempt = 2
            while fm.fileExists(atPath: backup.path) {
                backup = cli.appendingPathExtension("legacy-\(stamp(now))-\(attempt)")
                attempt += 1
            }
            do { try fm.moveItem(at: cli, to: backup) } catch { return .failure(error) }
        }
        do {
            try fm.createDirectory(
                at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: cli, withDestinationURL: executable)
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    /// The date a replaced binary was set aside, in the name of the file that
    /// holds it — so a person looking at the directory a year later can tell.
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay]
        return formatter.string(from: date)
    }
}
