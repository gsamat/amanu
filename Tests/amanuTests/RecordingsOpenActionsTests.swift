import AppKit
import Foundation
import Testing

@testable import amanu

struct RecordingsOpenActionsTests {
    @Test("Open Transcript is available when Markdown or canonical JSON exists")
    @MainActor
    func transcriptButtonTracksReadableFile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-open-actions-\(UUID().uuidString)")
        let session = root.appendingPathComponent("2026-09-23-120000-meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))

        let window = RecordingsWindow(root: root)
        let views = window.view?.allDescendants ?? []
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let button = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "open-transcript" })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!button.isEnabled)

        let transcript = Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-23T12:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello.")]
        )
        try JSONEncoder().encode(transcript)
            .write(to: session.appendingPathComponent("transcript.json"))
        window.show()
        await window.settled()
        #expect(button.isEnabled)

        try FileManager.default.removeItem(at: session.appendingPathComponent("transcript.json"))
        try Data("# Meeting\n".utf8).write(to: session.appendingPathComponent("transcript.md"))
        window.show()
        await window.settled()
        #expect(button.isEnabled)
        #expect(button.target != nil)
        #expect(button.action != nil)
        withExtendedLifetime(window) {}
    }

    @Test("The transcript uses its default app and falls back to a text editor")
    @MainActor
    func transcriptOpeningFallsBackOnlyWhenNeeded() {
        let file = URL(fileURLWithPath: "/tmp/transcript.md")
        var opened: [String] = []

        RecordingsWindow.openTranscript(file,
            openDefault: { url in
                #expect(url == file)
                opened.append("default")
                return true
            },
            openTextEdit: { _ in opened.append("TextEdit") })
        #expect(opened == ["default"])

        opened.removeAll()
        RecordingsWindow.openTranscript(file,
            openDefault: { _ in
                opened.append("default")
                return false
            },
            openTextEdit: { url in
                #expect(url == file)
                opened.append("TextEdit")
            })
        #expect(opened == ["default", "TextEdit"])
    }

    @Test("A canonical transcript without Markdown is made readable before opening")
    @MainActor
    func missingMarkdownIsRebuilt() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-rebuild-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let transcript = Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-23T12:00:00Z",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello, team."),
            ]
        )
        try JSONEncoder().encode(transcript)
            .write(to: session.appendingPathComponent("transcript.json"))

        let file = try #require(RecordingsWindow.readableTranscript(in: session))
        #expect(file.lastPathComponent == "transcript.md")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Hello, team."))
    }

    @Test("Copy summary is available only when a summary exists")
    @MainActor
    func copySummaryButtonTracksSummary() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-copy-summary-\(UUID().uuidString)")
        let session = root.appendingPathComponent("2026-09-23-120000-meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))

        let window = RecordingsWindow(root: root)
        let views = window.view?.allDescendants ?? []
        let table = try #require(views.compactMap { $0 as? NSTableView }.first)
        let button = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "copy-summary" })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(!button.isEnabled)

        try Data("## What this was about\n\nA meeting.\n".utf8)
            .write(to: session.appendingPathComponent("summary.md"))
        window.show()
        await window.settled()
        #expect(button.isEnabled)
        #expect(button.target != nil)
        #expect(button.action != nil)
        withExtendedLifetime(window) {}
    }

    @Test("A copied summary pastes as Markdown text and as uncoloured rich text")
    @MainActor
    func copiedSummaryCarriesBothForms() throws {
        let pasteboard = NSPasteboard(name: .init("amanu-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let summary = "## Key points\n\n- First\n- Second\n"
        RecordingsWindow.copy(summary: summary, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == summary)
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let pasted = try NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        #expect(pasted.string.contains("• First"))
        #expect(!pasted.string.contains("##"))
    }

    @Test("Whitespace alone is not a summary to copy")
    @MainActor
    func blankSummaryIsNothing() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-blank-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        #expect(RecordingsWindow.summary(in: session) == nil)
        try Data("  \n".utf8).write(to: session.appendingPathComponent("summary.md"))
        #expect(RecordingsWindow.summary(in: session) == nil)
    }

    @Test("A numbered list inside a bullet keeps its own numbers")
    @MainActor
    func nestedOrderedListIsNumberedByItself() {
        let markdown = """
            - One
            - Two
            - Three stages:
              1. Upload
              2. Generate
              3. Launch
            """
        let text = MarkdownPreview.render(markdown).string
        #expect(text.contains("1. Upload"))
        #expect(text.contains("2. Generate"))
        #expect(text.contains("3. Launch"))
        #expect(text.contains("• Three stages:"))
    }
}
