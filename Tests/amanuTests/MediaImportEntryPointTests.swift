import AppKit
import Testing
import UniformTypeIdentifiers
@testable import amanu

@Suite("Media import entry points")
@MainActor
struct MediaImportEntryPointTests {
    @Test("The application File menu imports several audio or video files with Command-I")
    func applicationMenuOffersImport() throws {
        let delegate = AppDelegate()
        var calls = 0
        delegate.onImport = { calls += 1 }

        let main = Run.mainMenu(settingsTarget: delegate)
        let file = try #require(main.items.compactMap(\.submenu).first { $0.title == "File" })
        let item = try #require(file.items.first { $0.title == "Import…" })

        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask.contains(.command))
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        #expect(calls == 1)
        withExtendedLifetime(delegate) {}
    }

    /// The status menu used to carry a third copy of Import. It is in the File
    /// menu of the application menu and in the window it belongs to, and in a
    /// menu about recording it was one door too many — so what is checked here
    /// is that it is gone from this one, and that it is still somewhere.
    @Test("The menu-bar menu leaves importing to the File menu and the window")
    func menuBarDoesNotOfferImport() throws {
        let menuBar = MenuBarController(visible: false)
        #expect(!menuBar.offeredItemTitles.contains("Import…"))

        let main = Run.mainMenu(settingsTarget: AppDelegate())
        let file = try #require(main.items.compactMap(\.submenu).first { $0.title == "File" })
        #expect(file.items.contains { $0.title == "Import…" })
        withExtendedLifetime(menuBar) {}
    }

    @Test("The import picker accepts multiple audio and video files, but not folders")
    func pickerConfiguration() {
        let panel = NSOpenPanel()
        MediaImportPicker.configure(panel)

        #expect(panel.allowsMultipleSelection)
        #expect(panel.canChooseFiles)
        #expect(!panel.canChooseDirectories)
        #expect(panel.allowedContentTypes.contains(.audio))
        #expect(panel.allowedContentTypes.contains(.movie))
    }
}
