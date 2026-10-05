import AppKit
import Testing
@testable import amanu

@Suite("Text editing shortcuts", .serialized)
@MainActor
struct TextEditingShortcutTests {
    @Test("Command-V pastes into API-key and ordinary text fields", arguments: [true, false])
    func pasteIntoFocusedField(secure: Bool) throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let delegate = AppDelegate()
        let menu = Run.mainMenu(settingsTarget: delegate)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.frame = NSRect(x: 20, y: 20, width: 280, height: 24)
        window.contentView?.addSubview(field)
        defer {
            window.close()
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
            withExtendedLifetime(delegate) {}
        }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        try #require(window.firstResponder === editor)
        // SwiftPM's test runner has no active application/key window. Supply
        // its real field editor as the receiver after checking that production
        // leaves the receiver to the responder chain.
        for item in menu.items.compactMap(\.submenu).flatMap(\.items) {
            if let action = item.action, editor.responds(to: action) {
                #expect(item.target == nil)
                item.target = editor
            }
        }
        editor.string = ""
        pasteboard.clearContents()
        pasteboard.setString("amanu-paste-regression", forType: .string)

        func command(_ characters: String, code: UInt16) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            let handled = menu.performKeyEquivalent(with: event)
            return handled
        }
        #expect(try command("v", code: 9))
        #expect(editor.string == "amanu-paste-regression")

        #expect(try command("a", code: 0))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 22))
        if !secure {
            pasteboard.clearContents()
            #expect(try command("c", code: 8))
            #expect(pasteboard.string(forType: .string) == "amanu-paste-regression")
            #expect(try command("x", code: 7))
            #expect(editor.string.isEmpty)
            #expect(try command("v", code: 9))
            #expect(editor.string == "amanu-paste-regression")
        }
    }
}
