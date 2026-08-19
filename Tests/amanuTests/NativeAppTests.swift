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

    @Test("Only a LaunchServices start makes this program answer for itself")
    func handOffDecision() {
        let bundle = Bundle.main

        // The two shell shapes. The double-forked one is why the parent
        // process id cannot be the test: it is reparented to launchd and is
        // still the terminal's responsibility.
        #expect(Runtime.shouldHandOffToBundle(
            bundle: bundle, environment: ["XPC_SERVICE_NAME": "0"]))
        #expect(Runtime.shouldHandOffToBundle(bundle: bundle, environment: [:]))

        #expect(!Runtime.shouldHandOffToBundle(
            bundle: bundle,
            environment: ["XPC_SERVICE_NAME": "application.me.samat.amanu.18516703.18517717"]))

        // A bare build has nowhere to hand over to.
        #expect(!Runtime.shouldHandOffToBundle(
            bundle: nil, environment: ["XPC_SERVICE_NAME": "0"]))

        // And the copy we opened never opens another, however it reads its
        // own launch.
        #expect(!Runtime.shouldHandOffToBundle(
            bundle: bundle,
            environment: ["XPC_SERVICE_NAME": "0", Runtime.handOffMarker: "1"]))
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

    /// The suite used to be run as `AMANU_NO_NOTIFY=1 swift test`, because a
    /// bare binary posted its banners through `osascript` and the test run
    /// sprayed them across the screen. Posting moved inside the bundle, and
    /// the bundle check made the env var redundant — but redundant is not the
    /// same as pinned, and the thing being relied on now is a property of the
    /// test binary rather than a flag anyone can see. So ask it out loud.
    @Test("A bare build has no bundle to post banners under, and stays quiet")
    func testsPostNothing() {
        #expect(!Runtime.isBundled)
        #expect(!Notifications.usesNotificationCenter)
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

/// The wizard is the first run, and after it the menus stop offering it: the
/// form it holds lives in Settings for good, and the rest of the window —
/// the order the grants have to happen in, the line saying what is still
/// outstanding — has been answered by then.
///
/// The item is in two menus, which is the thing worth a test: it was added to
/// both by hand, and hiding one of them is a fix that looks finished.
@Suite("Setup is offered while there is a first run to finish")
@MainActor
struct SetupOfferTests {
    @Test("The status item's menu offers Setup only while it is wanted")
    func statusMenuHidesSetup() {
        let menuBar = MenuBarController()
        defer { withExtendedLifetime(menuBar) {} }

        menuBar.setupAvailable(true)
        #expect(menuBar.offeredItemTitles.contains("Setup…"))

        menuBar.setupAvailable(false)
        #expect(!menuBar.offeredItemTitles.contains("Setup…"))

        // `amanu setup` resets the marker, and the way back has to be a way
        // back: an item that only ever disappears is a one-way door.
        menuBar.setupAvailable(true)
        #expect(menuBar.offeredItemTitles.contains("Setup…"))
    }

    /// About is where a Mac user looks for a name, and there are two menus
    /// it could be missing from. In the application menu it is also first,
    /// which is where every Mac puts it.
    @Test("About Amanu is offered in both menus")
    @MainActor
    func aboutIsInBothMenus() throws {
        let menuBar = MenuBarController()
        defer { withExtendedLifetime(menuBar) {} }
        #expect(menuBar.offeredItemTitles.contains("About Amanu"))

        let menu = Run.mainMenu(settingsTarget: AppDelegate())
        let appMenu = try #require(menu.items.first?.submenu)
        #expect(appMenu.items.first?.title == "About Amanu")
    }

    /// The window itself: three links, and each going where it says.
    @Test("The About window names its author and links to the source and the studio")
    @MainActor
    func aboutWindowOffersThreeLinks() {
        let about = AboutWindow()
        #expect(about.offeredLinks.map(\.title)
            == ["Samat Galimov ↗", "Source code on GitHub ↗", "Order custom development ↗"])
        #expect(about.offeredLinks.map(\.url) == [
            "https://samat.me",
            "https://github.com/gsamat/amanu",
            "https://fans.dev",
        ])
    }

    @Test("The app menu's Setup follows the same answer, and Settings never does")
    func appMenuHidesSetup() throws {
        let delegate = AppDelegate()
        let menu = Run.mainMenu(settingsTarget: delegate)
        let appMenu = try #require(menu.items.first?.submenu)
        let setup = try #require(appMenu.items.first { $0.title == "Setup…" })
        let settings = try #require(appMenu.items.first { $0.title == "Settings…" })

        delegate.setupAvailable(false)
        #expect(setup.isHidden)
        #expect(!settings.isHidden, "Settings is the door that must not close")

        delegate.setupAvailable(true)
        #expect(!setup.isHidden)

        withExtendedLifetime(delegate) {}
    }

    /// The initial state is not the controller's to set: the menu is built
    /// after the controller has already asked once, so an item born visible
    /// on a machine that finished setup last month would stay visible.
    @Test("The app menu is built already knowing whether setup is pending")
    func appMenuStartsFromTheMarker() throws {
        let delegate = AppDelegate()
        let menu = Run.mainMenu(settingsTarget: delegate)
        let appMenu = try #require(menu.items.first?.submenu)
        let setup = try #require(appMenu.items.first { $0.title == "Setup…" })

        #expect(setup.isHidden == !SetupState.isPending)
        withExtendedLifetime(delegate) {}
    }
}
