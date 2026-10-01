import AppKit
import Foundation
import Testing

@testable import amanu

/// The recordings window keeping up with a folder that other things write
/// into: the transcription queue, a moved recordings folder, a session that
/// is still being worked on.
@Suite(.serialized)
@MainActor
struct RecordingsWindowTests {
    private static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func session(_ name: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "started": "2026-09-28T09:00:00Z", "duration_seconds": 600, "title": name,
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private static func transcribe(_ dir: URL) throws {
        try JSONEncoder().encode(Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-28T09:11:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello.")]
        )).write(to: dir.appendingPathComponent("transcript.json"))
    }

    /// What the one row's transcript column says: `listLines` is the column
    /// titles, then each row's cells in column order.
    private static func transcriptCell(_ window: RecordingsWindow) -> String? {
        let lines = window.listLines
        return lines.count >= 8 ? lines[7] : nil
    }

    @Test("Selecting another recording replaces both previews, including missing files")
    func previewsFollowSelection() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try Self.session("2026-09-28-100000-first", in: root)
        try Self.transcribe(first)
        try Data("A decision from the first meeting.".utf8)
            .write(to: first.appendingPathComponent("summary.md"))
        try Self.session("2026-09-28-090000-second", in: root)
        let window = RecordingsWindow(root: root)
        let views = window.view?.allDescendants ?? []
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let tabs = try #require(views.compactMap { $0 as? NSTabView }.first)
        let summary = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "summary" }?.view?
            .allDescendants.compactMap { $0 as? NSTextView }.first)
        let transcript = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == "transcript" }?.view?
            .allDescendants.compactMap { $0 as? NSTextView }.first)
        let firstRow = try #require(window.listLines.firstIndex { $0.hasPrefix("2026-09-28-100000-first") })
        // The table contains five columns, preceded by five headings.
        table.selectRowIndexes([(firstRow - 5) / 5], byExtendingSelection: false)
        #expect(summary.string == "A decision from the first meeting.")
        #expect(transcript.string.contains("Hello."))
        #expect(!summary.isEditable && summary.isSelectable)
        table.selectRowIndexes([table.selectedRow == 0 ? 1 : 0], byExtendingSelection: false)
        #expect(!summary.string.contains("first meeting"))
        #expect(!transcript.string.contains("Hello."))
        table.deselectAll(nil)
        #expect(summary.string.isEmpty && transcript.string.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test("Recording previews display Markdown headings, lists, emphasis and links")
    func previewsRenderMarkdown() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        let markdown = "# Decisions\n\nA **bold** decision.\n\n- First\n- Second\n\n1. Next\n2. Last\n\n[Reference](https://example.com)"
        for file in ["summary.md", "transcript.md"] {
            try Data(markdown.utf8).write(to: dir.appendingPathComponent(file))
        }
        let recordings = RecordingsWindow(root: root)
        let tabs = try #require(recordings.view?.allDescendants.compactMap { $0 as? NSTabView }.first)
        for identifier in ["summary", "transcript"] {
            let text = try #require(tabs.tabViewItems.first { ($0.identifier as? String) == identifier }?.view?
                .allDescendants.compactMap { $0 as? NSTextView }.first)
            #expect(text.string == "Decisions\nA bold decision.\n• First\n• Second\n1. Next\n2. Last\nReference")
            let storage = try #require(text.textStorage)
            let heading = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            #expect(heading.pointSize > 13)
            let boldRange = (text.string as NSString).range(of: "bold")
            let bold = try #require(storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
            let linkRange = (text.string as NSString).range(of: "Reference")
            #expect(storage.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
                    == URL(string: "https://example.com"))
        }
        withExtendedLifetime(recordings) {}
    }

    @Test("Making the window taller gives the space to the recording content")
    func recordingContentFillsWindow() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingsWindow(root: root)
        let view = try #require(recordings.view)
        let window = try #require(view.window)
        let split = try #require(view.allDescendants.compactMap { $0 as? NSSplitView }.first)
        window.setContentSize(NSSize(width: 980, height: 700))
        view.layoutSubtreeIfNeeded()
        let before = split.frame.height
        window.setContentSize(NSSize(width: 980, height: 900))
        view.layoutSubtreeIfNeeded()
        #expect(split.frame.height >= before + 190)
        #expect(split.frame.minY < 7, "unused space should belong to the recording panes")
        split.setPosition(250, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        #expect(abs(split.arrangedSubviews[0].frame.height - 250) < 2,
                "the divider must let the user give more room to the recording details")
        withExtendedLifetime(recordings) {}
    }

    @Test("A long opening excerpt leaves room for speaker name fields")
    func speakerFieldsStayVisible() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        try JSONEncoder().encode(Transcript(
            engine: "assemblyai", model: "universal", created_at: "2026-09-28T09:11:00Z",
            segments: (0..<20).map { index in
                .init(speaker: index.isMultiple(of: 2) ? "A" : "B", start_ms: index * 1000,
                      end_ms: (index + 1) * 1000, text: "We discussed the plans for our next meeting and the work ahead.")
            }
        )).write(to: dir.appendingPathComponent("transcript.json"))
        let recordings = RecordingsWindow(root: root)
        let view = try #require(recordings.view)
        let tabs = try #require(view.allDescendants.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "speakers")
        view.layoutSubtreeIfNeeded()
        let speakers = try #require(tabs.selectedTabViewItem?.view)
        let scroll = try #require(speakers.allDescendants.compactMap { $0 as? NSScrollView }.first)
        let field = try #require(speakers.allDescendants.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let visible = field.convert(field.bounds, to: scroll.contentView)
        #expect(visible.intersects(scroll.contentView.bounds), "the excerpt must not push names out of view")
        #expect(tabs.contentRect.contains(field.convert(field.bounds, to: tabs)),
                "the name field must be inside the visible tab, not below its bottom edge")
        withExtendedLifetime(recordings) {}
    }

    @Test("Long speaker excerpts do not increase the window's minimum width")
    func speakersDoNotForceWindowWider() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-meeting", in: root)
        let longText = String(repeating: "We discussed the next meeting and agreed on the plan. ", count: 30)
        try JSONEncoder().encode(Transcript(
            engine: "assemblyai", model: "universal", created_at: "2026-09-28T09:11:00Z",
            segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: longText)]
        )).write(to: dir.appendingPathComponent("transcript.json"))
        let recordings = RecordingsWindow(root: root)
        let view = try #require(recordings.view)
        let window = try #require(view.window)
        let tabs = try #require(view.allDescendants.compactMap { $0 as? NSTabView }.first)
        window.setContentSize(NSSize(width: 860, height: 700))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        tabs.selectTabViewItem(withIdentifier: "speakers")
        view.layoutSubtreeIfNeeded()
        // AppKit applies the window's constraint-derived minimum on its next update.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let speakers = try #require(tabs.selectedTabViewItem?.view)
        #expect(speakers.fittingSize.width <= 820,
                "the speaker pane must be compressible to the available tab width")
        #expect(view.fittingSize.width <= 860,
                "spoken text must fit the pane instead of raising the window's minimum width")
        window.setContentSize(NSSize(width: 860, height: 700))
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        #expect(view.bounds.width <= 860)
        withExtendedLifetime(recordings) {}
    }

    @Test("Switching meetings keeps the speaker pane anchored inside its tab")
    func speakerPaneDoesNotDrift() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026-09-28-100000-first", "2026-09-28-090000-second"] {
            try Self.transcribe(Self.session(name, in: root))
        }
        let recordings = RecordingsWindow(root: root)
        let view = try #require(recordings.view)
        let window = try #require(view.window)
        let table = try #require(view.allDescendants.compactMap { $0 as? NSTableView }.first)
        let tabs = try #require(view.allDescendants.compactMap { $0 as? NSTabView }.first)
        window.setContentSize(NSSize(width: 980, height: 700))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        tabs.selectTabViewItem(withIdentifier: "speakers")
        for index in 0..<12 {
            table.selectRowIndexes([index % 2], byExtendingSelection: false)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            let pane = try #require(tabs.selectedTabViewItem?.view)
            #expect(abs(pane.frame.minX - tabs.contentRect.minX) < 1,
                    "speaker pane moved horizontally after selection \(index): \(pane.frame)")
            #expect(abs(pane.frame.minY - tabs.contentRect.minY) < 1,
                    "speaker pane moved vertically after selection \(index): \(pane.frame)")
        }
        withExtendedLifetime(recordings) {}
    }

    /// It read the folder when it was opened and never again, so a meeting
    /// transcribed while it was open went on showing as waiting, and Finish
    /// processing acted on what the window last saw.
    @Test("A transcript finished while the window is open shows up in it")
    func finishedWorkIsShown() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-standup", in: root)

        let window = RecordingsWindow(root: root)
        window.show()
        defer { withExtendedLifetime(window) {} }
        let before = Self.transcriptCell(window)

        try Self.transcribe(dir)
        window.sessionsChanged()
        await window.settled()

        #expect(Self.transcriptCell(window) != before, "the window still shows the transcript as owed")
        #expect(Self.transcriptCell(window)?.hasPrefix(
            SessionInventory.Step.done.described) == true)
    }

    @Test("A closed window does not read the folder until it is opened")
    func closedWindowWaits() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let window = RecordingsWindow(root: root)
        defer { withExtendedLifetime(window) {} }
        try Self.session("2026-09-28-100000-later", in: root)
        window.sessionsChanged()
        await window.settled()
        #expect(!window.listLines.contains("2026-09-28-100000-later"))
    }

    @Test("Moved to another recordings folder, the window lists that folder")
    func anotherFolderIsListed() async throws {
        let first = try Self.folder()
        let second = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Self.session("2026-09-28-090000-old-folder", in: first)
        try Self.session("2026-09-28-090000-new-folder", in: second)

        let window = RecordingsWindow(root: first)
        defer { withExtendedLifetime(window) {} }
        #expect(window.listLines.contains { $0.hasPrefix("2026-09-28-090000-old-folder") })

        window.setRoot(second)
        await window.settled()
        #expect(window.listLines.contains { $0.hasPrefix("2026-09-28-090000-new-folder") })
        #expect(!window.listLines.contains { $0.hasPrefix("2026-09-28-090000-old-folder") })
    }

    /// Delete moved a folder to the Trash while the transcription queue was
    /// writing into it.
    @Test("A recording something is working on cannot be deleted, and says why")
    func heldSessionIsNotDeleted() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-busy", in: root)

        #expect(RecordingsWindow.deleteRefusal(for: dir) == nil)

        try SessionClaim.acquire(dir, stage: .transcribe)
        let why = RecordingsWindow.deleteRefusal(for: dir)
        SessionClaim.release(dir)

        #expect(why?.contains("working on this recording") == true)
        #expect(RecordingsWindow.deleteRefusal(for: dir) == nil)
    }
}
