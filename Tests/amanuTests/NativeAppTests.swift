import Foundation
import Testing

@testable import amanu

@Suite("Living inside an application bundle")
struct NativeAppTests {
    @Test("Window-server arguments are not commands anyone typed")
    func launchServicesArguments() {
        let launched = Runtime.meaningfulArguments([
            "/Applications/Amanu.app/Contents/MacOS/Amanu",
            "-psn_0_123456",
            "-NSDocumentRevisionsDebugMode", "YES",
        ])
        #expect(launched == ["/Applications/Amanu.app/Contents/MacOS/Amanu"])

        // What a person types survives untouched.
        let typed = ["amanu", "record", "start", "--out", "/tmp/x"]
        #expect(Runtime.meaningfulArguments(typed) == typed)
    }

    @Test("Start at login is a question only an application can answer")
    @MainActor
    func startAtLoginPolicy() {
        #expect(!SetupPermissions.needsStartAtLogin(loginItem: .enabled))
        #expect(SetupPermissions.needsStartAtLogin(loginItem: .notRegistered))
        #expect(SetupPermissions.needsStartAtLogin(loginItem: .needsApproval))
        // A bare build has nothing to register, and saying so in the window
        // would be asking for something nobody can do.
        #expect(!SetupPermissions.needsStartAtLogin(loginItem: .unavailable))
    }

    @Test("Pointing the CLI at the app is safe to repeat, and never eats a binary")
    func cliRelink() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let cli = dir.appendingPathComponent("amanu")
        let app = dir.appendingPathComponent("Amanu.app/Contents/MacOS/Amanu")
        let older = dir.appendingPathComponent("Older.app/Contents/MacOS/Amanu")
        let day = Date(timeIntervalSince1970: 1_755_000_000)

        // A real binary is kept, under a name that says when it was retired.
        try Data("binary".utf8).write(to: cli)
        #expect(try AgentCLI.link(at: cli, to: app, now: day).get())
        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == app.path)
        let backups = try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("amanu.legacy-") }
        #expect(backups.count == 1)

        // Running it again changes nothing and reports so.
        #expect(try AgentCLI.link(at: cli, to: app, now: day).get() == false)

        // A symlink from an earlier install is replaced, not preserved — and
        // the backup name being taken doesn't stop it.
        #expect(try AgentCLI.link(at: cli, to: older, now: day).get())
        #expect(try fm.destinationOfSymbolicLink(atPath: cli.path) == older.path)
        #expect(try fm.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("amanu.legacy-") }.count == 1)
    }

    @Test("A banner carries the recording it is about")
    func notificationCarriesItsSession() {
        let folder = URL(fileURLWithPath: "/Users/x/Recordings/2026.08.18-2300 Standup")
        var userInfo: [AnyHashable: Any] = [:]
        userInfo["me.samat.amanu.session"] = folder.path

        #expect(Notifications.session(in: userInfo) == folder)
        #expect(Notifications.session(in: [:]) == nil)
        #expect(Notifications.session(in: ["me.samat.amanu.session": 42]) == nil)
    }
}
