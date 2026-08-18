import ArgumentParser
import Foundation

/// Start at login, from the command line.
///
/// This used to write a LaunchAgent plist, because a bare binary had no other
/// way to be the process macOS holds responsible for system audio. Amanu.app
/// is that process by being an application, so the command now does what the
/// Setup window's switch does: registers the bundle with `SMAppService`, where
/// System Settings shows it under Login Items alongside everything else.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start amanu at login, or stop it starting."
    )

    @Flag(name: .long, help: "Register amanu to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Stop amanu starting at login.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }
        guard Runtime.isBundled else {
            throw CleanExit.message(
                "this copy isn't Amanu.app — build it with `make app`, put it in "
                    + "/Applications, and run it from there.")
        }

        if uninstall {
            try LoginItem.unregister()
            print("✓ amanu will no longer start at login")
            return
        }
        let state = try LoginItem.register()
        print(state == .needsApproval
            ? "! registered — allow amanu in System Settings → General → Login Items"
            : "✓ amanu will start at login")
    }
}
