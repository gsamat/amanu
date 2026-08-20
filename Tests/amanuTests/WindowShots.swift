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

            // The Advanced tab is taller than any window it can be shown in,
            // and what is at the bottom of it — the models on disk, which is
            // the one block here that is not a setting — appears in no
            // picture taken from the top.
            panel.setContentSize(NSSize(width: 700, height: 900))
            scrollToBottom(in: tabs.selectedTabViewItem?.view)
            try write(panel, "settings-advanced-\(name)-bottom")
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

    /// The About window, which is small enough that both appearances fit in
    /// one pass and has no state to drive it through. What there is to see is
    /// the spacing: an icon, a name, a version and three links, centred, and
    /// Russian is a fifth longer than English at every one of them.
    @Test("The About window, in both appearances")
    @MainActor
    func aboutWindow() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            let panel = try aboutPanel(builtIn: appearance, keeping: &owners)
            try write(panel, "about-\(name)")
        }
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

    /// Put every scroller in a view at the end of its content, so a picture
    /// of it shows what is down there rather than what is at the top.
    @MainActor
    private func scrollToBottom(in view: NSView?) {
        guard let view else { return }
        view.layoutSubtreeIfNeeded()

        var pending = [view]
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            guard let scroll = next as? NSScrollView,
                  let document = scroll.documentView else { continue }
            // The forms in these windows are flipped, so the end of the
            // content is the largest y rather than the smallest.
            let hidden = document.frame.height - scroll.contentView.bounds.height
            guard hidden > 0 else { continue }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: hidden))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        view.layoutSubtreeIfNeeded()
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
    private func aboutPanel(
        builtIn appearance: NSAppearance?, keeping owners: inout [Any]
    ) throws -> NSWindow {
        NSApp.appearance = appearance
        var window: AboutWindow?
        appearance?.performAsCurrentDrawingAppearance { window = AboutWindow() }
        let about = try #require(window)
        owners.append(about)
        let panel = try #require(NSApp.windows.last { $0.title == about.title })
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

/// The two windows the suite above does not build, and the setup window at the
/// one size a person never sees it.
///
/// `WindowShots` grew around the two windows that produce layout defects, and
/// stopped there. But amanu has five windows, and a set of pictures meant to
/// show somebody what the program looks like — in one language beside the
/// other — cannot be missing the one that says whether it is recording and the
/// one that lists what it recorded. Neither needs the appearance-switch pass:
/// that is a diagnostic for forms built before their window exists, and these
/// two build theirs in place.
///
/// Same switch, same directory, same two languages:
///
/// ```sh
/// AMANU_SHOTS=/tmp/shots swift test --filter WindowGallery
/// ```
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AMANU_SHOTS"] != nil))
struct WindowGallery {
    private var directory: String {
        ProcessInfo.processInfo.environment["AMANU_SHOTS"] ?? NSTemporaryDirectory()
    }

    private var language: InterfaceLanguage {
        ProcessInfo.processInfo.environment["AMANU_SHOTS_LANGUAGE"]
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .english
    }

    private var light: NSAppearance? { NSAppearance(named: .aqua) }
    private var dark: NSAppearance? { NSAppearance(named: .darkAqua) }

    /// The setup window at exactly the height of its own form.
    ///
    /// The pair in `WindowShots` is deliberately the wrong height twice: 760
    /// is what a person gets and scrolls, 1600 is taller than the form so that
    /// anything anchored to the bottom shows itself. Neither is the picture to
    /// hand somebody who asked what the setup screen looks like — one is cut
    /// off and the other has a band of empty window under it. This one is
    /// measured: the form is laid out tall, its real height read back, and the
    /// window closed onto it, so the whole screen is in one image with no
    /// scrollbar and nothing to spare.
    @Test("The setup window at the full height of its form")
    @MainActor
    func setupWhole() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            NSApp.appearance = appearance
            var window: SetupWindow?
            appearance?.performAsCurrentDrawingAppearance { window = SetupWindow() }
            owners.append(try #require(window))
            let title = localised("amanu setup", "Первая настройка amanu")
            let panel = try #require(NSApp.windows.last { $0.title == title })
            panel.appearance = appearance

            // Lay the form out somewhere it certainly fits, read what it came
            // to, then take the window down to it. Asking a scroll view for
            // its document's height before it has been given room to lay one
            // out answers with the height it was given.
            panel.setContentSize(NSSize(width: 700, height: 2000))
            panel.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(panel.contentView)
            let scroll = try #require(firstScrollView(in: content))
            let document = try #require(scroll.documentView)
            let chrome = content.bounds.height - scroll.bounds.height
            panel.setContentSize(NSSize(
                width: panel.contentLayoutRect.width,
                height: ceil(document.bounds.height + chrome)))
            try write(panel, "setup-\(name)-whole")
        }
    }

    /// The status window, in the two states it is ever in.
    ///
    /// Idle is the one that is on screen all day, and the one whose wording
    /// this release changed. Recording is the other shape of the window
    /// entirely: the live transcript borrows the height while it runs, which
    /// is the only time this window is bigger than a postage stamp.
    @Test("The status window, idle and recording, in both appearances")
    @MainActor
    func statusWindow() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            NSApp.appearance = appearance
            var window: StatusWindow?
            appearance?.performAsCurrentDrawingAppearance { window = StatusWindow() }
            let status = try #require(window)
            owners.append(status)
            let panel = try #require(NSApp.windows.last { $0.title == "amanu" })
            panel.appearance = appearance

            status.update(state: .idle, elapsed: nil)
            status.updateAutoRecord(enabled: true, decision: localised("ready", "готов"))
            status.updateTranscription(localised(
                "transcribes on this Mac", "расшифровывает на этом маке"))
            status.updateLive(.init(
                isRecording: false, isEnabled: true, entries: [], status: .idle))
            try write(panel, "status-idle-\(name)")

            status.update(state: .recording, elapsed: "12:04")
            status.updateAutoRecord(
                enabled: true,
                decision: localised("Zoom on the mic for 12m", "Zoom на микрофоне 12 мин"))
            status.updateLive(.init(
                isRecording: true, isEnabled: true, entries: Self.conversation, status: .live))
            try write(panel, "status-recording-\(name)")
        }
    }

    /// The recordings window, over a folder made for the picture.
    ///
    /// Not over the real one: these files are for showing people, and the real
    /// folder is full of the names of actual meetings. The fixture is four
    /// sessions arranged to put every state the list can show in one frame —
    /// finished, waiting its turn, refused, and a recording whose audio has
    /// been cleaned out — with the newest selected so the detail side of the
    /// window has something in it.
    @Test("The recordings window, in both appearances")
    @MainActor
    func recordingsWindow() throws {
        _ = NSApplication.shared
        let spoken = InterfaceLanguage.current
        InterfaceLanguage.current = language
        defer { InterfaceLanguage.current = spoken }

        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        var owners: [Any] = []
        defer { withExtendedLifetime(owners) {} }

        for (name, appearance) in [("light", light), ("dark", dark)] {
            NSApp.appearance = appearance
            var window: RecordingsWindow?
            appearance?.performAsCurrentDrawingAppearance { window = RecordingsWindow(root: root) }
            owners.append(try #require(window))
            let title = localised("Recordings", "Записи")
            let panel = try #require(NSApp.windows.last { $0.title == title })
            panel.appearance = appearance
            panel.setContentSize(NSSize(width: 860, height: 560))

            let content = try #require(panel.contentView)
            content.layoutSubtreeIfNeeded()
            // The detail half of the window is empty until something is
            // selected, and an empty half is not what the window looks like.
            if let table = firstTableView(in: content), table.numberOfRows > 0 {
                table.selectRowIndexes([0], byExtendingSelection: false)
            }
            try write(panel, "recordings-\(name)")
        }
    }

    // MARK: - what the pictures are of

    /// A few lines of a meeting, long enough to fill the transcript pane and
    /// to run in both directions: the labels are the window's language, the
    /// speech is whatever was said.
    private static var conversation: [LiveTranscriptState.Entry] {
        [
            .speech(.init(speaker: .them, text: "Давай пройдёмся по релизу.",
                          startMilliseconds: 0, isProvisional: false)),
            .speech(.init(speaker: .you, text: "Yes — two changes and the notes are written.",
                          startMilliseconds: 2600, isProvisional: false)),
            .speech(.init(speaker: .them, text: "А ожидание после звонка починили?",
                          startMilliseconds: 6100, isProvisional: false)),
            .speech(.init(speaker: .you, text: "Fifteen seconds now, down from ninety.",
                          startMilliseconds: 9400, isProvisional: true)),
        ]
    }

    /// Four sessions on disk, covering the four things the list can say about
    /// one. Written into a folder of its own so nothing here can be confused
    /// for a real recording.
    private static func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try session(
            in: root, named: "2026.08.20-1030",
            meta: [
                "started": "2026-08-20T10:30:00Z", "duration_seconds": 2760,
                "title": localised("Release review", "Разбор релиза"),
                "trigger": "mic-activity",
            ],
            transcript: true, speakers: true, summary: true)

        try session(
            in: root, named: "2026.08.19-1615",
            meta: [
                "started": "2026-08-19T16:15:00Z", "duration_seconds": 1500,
                "title": localised("Weekly with Fyodor", "Планёрка с Фёдором"),
                "trigger": "calendar",
            ],
            transcript: true, speakers: false, summary: false)

        try session(
            in: root, named: "2026.08.19-0905",
            meta: [
                "started": "2026-08-19T09:05:00Z", "duration_seconds": 480,
                "title": localised("Call with the studio", "Звонок со студией"),
                "trigger": "mic-activity",
                SessionState.Key.transcriptionFailed:
                    "no spoken audio in the recording",
            ],
            transcript: false, speakers: false, summary: false)

        try session(
            in: root, named: "2026.08.18-1400",
            meta: [
                "started": "2026-08-18T14:00:00Z", "duration_seconds": 3600,
                "title": localised("Design conversation", "Разговор про дизайн"),
                "trigger": "manual",
            ],
            transcript: true, speakers: true, summary: true)

        return root
    }

    private static func session(
        in root: URL, named name: String, meta: [String: Any],
        transcript: Bool, speakers: Bool, summary: Bool
    ) throws {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))

        if transcript {
            let json = Transcript(
                engine: "parakeet", model: "v3", created_at: "2026-08-20T11:20:00Z",
                segments: [
                    .init(speaker: "me", start_ms: 0, end_ms: 2400,
                          text: "Let's go through what's left."),
                    .init(speaker: "them A", start_ms: 2400, end_ms: 6100,
                          text: "Две правки и заметки к релизу."),
                    .init(speaker: "them B", start_ms: 6100, end_ms: 9000,
                          text: "I'll take the checklist."),
                ]
            )
            try JSONEncoder().encode(json)
                .write(to: dir.appendingPathComponent("transcript.json"))
        }
        if speakers {
            try SpeakerNames(speakers: [
                "them A": .init(name: "Фёдор", source: .model),
                "them B": .init(name: "Мария", source: .manual),
            ]).write(to: dir)
        }
        if summary {
            try Data("# notes\n\nTwo changes, and the notes are written.\n".utf8)
                .write(to: dir.appendingPathComponent("summary.md"))
        }
    }

    // MARK: - finding things in a window

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let scroll = firstScrollView(in: sub) { return scroll }
        }
        return nil
    }

    @MainActor
    private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let table = firstTableView(in: sub) { return table }
        }
        return nil
    }

    // MARK: - taking the picture

    /// The same exposure as `WindowShots.write(_:_:)`, and for the same
    /// reasons — see the comment there about the background.
    @MainActor
    private func write(_ panel: NSWindow, _ name: String) throws {
        let view = try #require(panel.contentView)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        view.displayIfNeeded()

        let bounds = view.bounds
        let ground = GalleryGround(frame: bounds)
        ground.autoresizingMask = [.width, .height]
        view.addSubview(ground, positioned: .below, relativeTo: nil)
        defer { ground.removeFromSuperview() }

        let shot = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: shot)
        let png = try #require(shot.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }
}

private final class GalleryGround: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
