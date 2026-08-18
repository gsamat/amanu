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

    @Test("Start at login asks a different question of an app than of a binary")
    @MainActor
    func startAtLoginDependsOnHowItRuns() {
        #expect(!SetupPermissions.needsStartAtLogin(bundled: true, loginItem: .enabled))
        #expect(SetupPermissions.needsStartAtLogin(bundled: true, loginItem: .notRegistered))
        #expect(SetupPermissions.needsStartAtLogin(bundled: true, loginItem: .needsApproval))
        // Unbundled, the login-item state is irrelevant: what matters is the
        // LaunchAgent, which this process either is under or isn't.
        #expect(
            SetupPermissions.needsStartAtLogin(bundled: false, loginItem: .unavailable)
                == SetupPermissions.needsLaunchAgentHandoff)
    }

    @Test("Only the LaunchAgent amanu wrote is retired by amanu")
    func migrationRecognisesItsOwnJob() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ job: [String: Any], as name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let data = try PropertyListSerialization.data(
                fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: url)
            return url
        }

        let ours = try write([
            "Label": "me.samat.amanu",
            "ProgramArguments": ["/Users/x/.local/bin/amanu", "run"],
        ], as: "ours.plist")
        #expect(LegacyMigration.isOurs(ours))

        // Same label, someone else's program: not ours to stop or delete.
        let impostor = try write([
            "Label": "me.samat.amanu",
            "ProgramArguments": ["/usr/local/bin/something-else", "--daemon"],
        ], as: "impostor.plist")
        #expect(!LegacyMigration.isOurs(impostor))

        let unrelated = try write([
            "Label": "com.example.other",
            "ProgramArguments": ["/Users/x/.local/bin/amanu"],
        ], as: "unrelated.plist")
        #expect(!LegacyMigration.isOurs(unrelated))

        #expect(!LegacyMigration.isOurs(dir.appendingPathComponent("absent.plist")))
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
