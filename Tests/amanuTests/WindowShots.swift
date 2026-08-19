import AppKit
import Foundation
import Testing

@testable import amanu

/// Pictures of the windows, and a listing of where every view in them ended
/// up, for a person to look at.
///
/// This is the only way the project has of seeing a window whole. `swift test`
/// can prove that a control exists and is wired to something; it cannot notice
/// that a label's descenders are sitting on the hairline below it, that a
/// border resolved to the other appearance's colour, or that two rows nobody
/// meant to compare came out different heights. Those are the defects this
/// window keeps producing, and each one was found by rendering it and looking.
///
/// It lives in the test target because that is the only place that can see
/// `SetupWindow` and `SettingsWindow` at all: they are internal, and making
/// them public so a command-line tool could open them would be widening the
/// program to suit its instruments. It is not a test — it asserts nothing —
/// so it is switched off unless `AMANU_SHOTS` names a directory to write to:
///
/// ```sh
/// AMANU_SHOTS=/tmp/shots swift test --filter WindowShots
/// ```
///
/// `AMANU_SHOTS_LANGUAGE=ru` takes the same pictures of the Russian windows.
/// The comparison worth making is one language against the other from the same
/// run: the translation is the only thing that differs, and Russian is longer
/// than English by a fifth, so a row that has run out of lines shows up in the
/// pair rather than in either picture alone.
///
/// `docs/testing/window-shots.md` says what comes out and how to read it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AMANU_SHOTS"] != nil))
struct WindowShots {
    private var directory: String {
        ProcessInfo.processInfo.environment["AMANU_SHOTS"] ?? NSTemporaryDirectory()
    }

    /// The language to build the windows in. Nothing else in the suite ever
    /// leaves English, so this is set and put back around each test rather
    /// than once for the process.
    private var language: InterfaceLanguage {
        ProcessInfo.processInfo.environment["AMANU_SHOTS_LANGUAGE"]
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .english
    }

    private var light: NSAppearance? { NSAppearance(named: .aqua) }
    private var dark: NSAppearance? { NSAppearance(named: .darkAqua) }

    @Test("The setup window, in both appearances and through a change of one")
    @MainActor
    func setupWindow() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            let panel = try setupPanel(builtIn: appearance, keeping: &owners)
            // The height a person actually gets, and then a window taller than
            // the form, which is where anchoring mistakes show up.
            panel.setContentSize(NSSize(width: 700, height: 760))
            try write(panel, "setup-\(name)-window")
            panel.setContentSize(NSSize(width: 700, height: 1600))
            try write(panel, "setup-\(name)-full")
        }

        // A window built under one appearance and shown under the other. Layer
        // colours are resolved numbers rather than living rules, so this is
        // the pass that catches a border still painted in the theme the Mac
        // has left — compare these against the two above, which should be
        // identical to the pixel.
        let panel = try setupPanel(builtIn: light, keeping: &owners)
        panel.setContentSize(NSSize(width: 700, height: 1600))
        show(panel, in: dark)
        try write(panel, "setup-switched-to-dark")
        show(panel, in: light)
        try write(panel, "setup-switched-back-to-light")
    }

    @Test("The settings window: both tabs, both appearances, and a change of one")
    @MainActor
    func settingsWindow() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            let panel = try settingsPanel(builtIn: appearance, keeping: &owners)
            panel.setContentSize(NSSize(width: 700, height: 900))
            let tabs = try tabs(of: panel)
            tabs.selectTabViewItem(at: 0)
            try write(panel, "settings-setup-\(name)")
            tabs.selectTabViewItem(at: 1)
            try write(panel, "settings-advanced-\(name)")
            // The narrowest the window goes. Some settings appear nowhere but
            // in their field's placeholder, so this is where to see one lost.
            panel.setContentSize(NSSize(width: 640, height: 900))
            try write(panel, "settings-advanced-\(name)-narrow")
        }

        // The setup form here is built before its window exists and then lives
        // in someone else's, which is the arrangement most likely to leave it
        // painted in the wrong appearance.
        let panel = try settingsPanel(builtIn: dark, keeping: &owners)
        panel.setContentSize(NSSize(width: 700, height: 900))
        try tabs(of: panel).selectTabViewItem(at: 0)
        show(panel, in: light)
        try write(panel, "settings-setup-switched-to-light")
        show(panel, in: dark)
        try write(panel, "settings-setup-switched-back-to-dark")
    }

    /// Every view in the setup window with its frame, in the window's own
    /// coordinates. This is what to measure against when a row looks a pixel
    /// wrong: eyes are bad at 2pt and this is exact.
    @Test("Where every view in the setup window ended up")
    @MainActor
    func viewTree() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        let panel = try setupPanel(builtIn: light, keeping: &owners)
        panel.setContentSize(NSSize(width: 700, height: 1600))
        let root = try #require(panel.contentView)
        root.layoutSubtreeIfNeeded()

        var lines: [String] = []
        describe(root, in: root, depth: 0, into: &lines)
        try lines.joined(separator: "\n").write(
            toFile: "\(directory)/tree.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - the windows

    /// The window objects own their views, and nothing else here holds one,
    /// so each is handed to `owners` for the caller to keep alive.
    @MainActor
    private func setupPanel(
        builtIn appearance: NSAppearance?, keeping owners: inout [Any]
    ) throws -> NSWindow {
        NSApp.appearance = appearance
        var window: SetupWindow?
        appearance?.performAsCurrentDrawingAppearance { window = SetupWindow() }
        owners.append(try #require(window))
        let title = localised("amanu setup", "Первая настройка amanu")
        let panel = try #require(NSApp.windows.last { $0.title == title })
        panel.appearance = appearance
        return panel
    }

    @MainActor
    private func settingsPanel(
        builtIn appearance: NSAppearance?, keeping owners: inout [Any]
    ) throws -> NSWindow {
        NSApp.appearance = appearance
        var window: SettingsWindow?
        appearance?.performAsCurrentDrawingAppearance { window = SettingsWindow() }
        owners.append(try #require(window))
        let title = localised("amanu settings", "Настройки amanu")
        let panel = try #require(NSApp.windows.last { $0.title == title })
        panel.appearance = appearance
        return panel
    }

    @MainActor
    private func tabs(of panel: NSWindow) throws -> NSTabView {
        func find(_ view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            for sub in view.subviews { if let tabs = find(sub) { return tabs } }
            return nil
        }
        let content = try #require(panel.contentView)
        return try #require(find(content))
    }

    /// Hand the window to the other appearance, the way the Mac does.
    @MainActor
    private func show(_ panel: NSWindow, in appearance: NSAppearance?) {
        NSApp.appearance = appearance
        panel.appearance = appearance
    }

    // MARK: - taking the picture

    /// Write the window's contents out, on a background.
    ///
    /// The background is the part worth explaining. `cacheDisplay` renders the
    /// views and nothing underneath them, so everything that is really the
    /// window rather than a view — the plain background, a tab view's material
    /// — comes out transparent, and a dark window's white text flattened onto
    /// white is a blank page. Rather than leave every reader of these files to
    /// know that, a plain view painted in `windowBackgroundColor` goes in
    /// behind the form for the length of the exposure.
    @MainActor
    private func write(_ panel: NSWindow, _ name: String) throws {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        // A change of appearance is repainted on a later turn of the run loop.
        // Without this the first picture after one catches a window halfway.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        view.displayIfNeeded()

        let bounds = view.bounds
        let ground = Ground(frame: bounds)
        ground.autoresizingMask = [.width, .height]
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        defer { ground.removeFromSuperview() }

        let shot = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: shot)
        let png = try #require(shot.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }

    // MARK: - the listing

    @MainActor
    private func describe(
        _ view: NSView, in root: NSView, depth: Int, into lines: inout [String]
    ) {
        let frame = view.convert(view.bounds, to: root)
        lines.append(String(
            format: "%@%@ x=%.1f y=%.1f w=%.1f h=%.1f %@%@",
            String(repeating: "  ", count: depth),
            "\(type(of: view))",
            frame.origin.x, frame.origin.y, frame.width, frame.height,
            view.isHidden ? "HIDDEN " : "",
            label(view)))
        for sub in view.subviews { describe(sub, in: root, depth: depth + 1, into: &lines) }
    }

    /// Enough of a view to recognise it in the listing. A switch reports its
    /// state here because it will not report it in a picture: an `NSSwitch` is
    /// drawn by SwiftUI, and offscreen it comes out in the off position
    /// whatever it is set to.
    @MainActor
    private func label(_ view: NSView) -> String {
        if let toggle = view as? NSSwitch { return "SWITCH \(toggle.state == .on ? "ON" : "off")" }
        if let menu = view as? NSPopUpButton { return "POPUP \"\(menu.titleOfSelectedItem ?? "")\"" }
        if let button = view as? NSButton { return "button \"\(button.title.prefix(30))\"" }
        if let field = view as? NSTextField {
            let shown = field.stringValue.isEmpty
                ? (field.placeholderString.map { "placeholder \"\($0)\"" } ?? "")
                : "\"\(field.stringValue.prefix(48))\""
            return shown
        }
        if let image = view as? NSImageView {
            return "image \(image.image?.accessibilityDescription ?? "—")"
        }
        return ""
    }
}

/// The paper the picture is taken on; see `write(_:_:)`. It draws rather than
/// tints a layer so that `cacheDisplay` renders it, and it reads the colour
/// inside `draw` so the colour is the one this appearance asks for.
private final class Ground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
