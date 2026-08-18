import Foundation

/// Moving a machine off the bare binary and onto `Amanu.app`.
///
/// The two must never run at once. Both hold the microphone, both watch for
/// call apps, and the recording that comes out of that is two half-recordings
/// with the same name. So the first thing a bundled amanu does is retire the
/// LaunchAgent that starts the old copy — and only the one it recognises as
/// its own. An unknown job with a familiar label belongs to someone else.
enum LegacyMigration {
    struct Result {
        var stoppedAgent = false
        var removedPlist = false
        var linkedCLI = false
        var notes: [String] = []
    }

    /// Runs at startup, before recording can begin. Every step is safe to
    /// repeat: a machine that has already been migrated does nothing here.
    @discardableResult
    static func run(
        plist: URL = Install.agentPlistURL,
        cli: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/amanu"),
        bundleExecutable: URL = Runtime.executableURL,
        now: Date = Date()
    ) -> Result {
        var result = Result()
        guard Runtime.isBundled else { return result }
        let fm = FileManager.default

        if fm.fileExists(atPath: plist.path) {
            if isOurs(plist) {
                if bootOut() { result.stoppedAgent = true }
                do {
                    try fm.removeItem(at: plist)
                    result.removedPlist = true
                } catch {
                    result.notes.append("couldn't remove \(plist.lastPathComponent): \(error)")
                }
            } else {
                result.notes.append(
                    "left \(plist.lastPathComponent) alone — it doesn't look like ours")
            }
        }

        // The CLI keeps working, because agents and scripts call it: it becomes
        // a symlink into the bundle, so an updated app updates it too.
        switch pointCLI(at: cli, to: bundleExecutable, now: now) {
        case .success(let changed): result.linkedCLI = changed
        case .failure(let error):
            result.notes.append("couldn't point \(cli.path) at the app: \(error)")
        }
        return result
    }

    /// Point `~/.local/bin/amanu` at the executable inside the bundle.
    ///
    /// An old symlink is simply replaced — it is a pointer, not anybody's
    /// file. A real binary is moved aside with the date rather than
    /// overwritten, and if that name is taken (a second migration on the same
    /// day, which is exactly what happens while this is being built) the
    /// backup is numbered instead of failing.
    static func pointCLI(at cli: URL, to executable: URL, now: Date) -> Swift.Result<Bool, Error> {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: cli.path) {
            guard existing != executable.path else { return .success(false) }
            do { try fm.removeItem(at: cli) } catch { return .failure(error) }
        } else if fm.fileExists(atPath: cli.path) {
            let stamp = legacyStamp(now)
            var backup = cli.appendingPathExtension("legacy-\(stamp)")
            var attempt = 2
            while fm.fileExists(atPath: backup.path) {
                backup = cli.appendingPathExtension("legacy-\(stamp)-\(attempt)")
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

    /// A job we wrote points at an executable called amanu. Anything else with
    /// this label was put there by someone who meant it.
    static func isOurs(_ plist: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: plist),
            let job = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any]
        else { return false }
        guard job["Label"] as? String == Install.label else { return false }
        let program = (job["ProgramArguments"] as? [String])?.first ?? job["Program"] as? String
        return program.map { URL(fileURLWithPath: $0).lastPathComponent == "amanu" } ?? false
    }

    private static func bootOut() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(Install.label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            // 3 is "no such process": already gone, which is the state we want.
            return task.terminationStatus == 0 || task.terminationStatus == 3
        } catch {
            return false
        }
    }
}

/// The date the old binary was set aside, in the name of the file that holds
/// it — so a person looking at the directory a year later can tell.
private func legacyStamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withYear, .withMonth, .withDay]
    return formatter.string(from: date)
}
