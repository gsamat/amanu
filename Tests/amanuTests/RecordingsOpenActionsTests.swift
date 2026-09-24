import AppKit
import Foundation
import Testing

@testable import amanu

struct RecordingsOpenActionsTests {
    @Test("Open Transcript is available when Markdown or canonical JSON exists")
    @MainActor
    func transcriptButtonTracksReadableFile() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-open-actions-\(UUID().uuidString)")
        let session = root.appendingPathComponent("2026-09-23-120000-meeting")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: session.appendingPathComponent("meta.json"))

        let window = RecordingsWindow(root: root)
        let table = try #require(descendants(of: window.view).compactMap { $0 as? NSTableView }.first)
        let button = try #require(descendants(of: window.view).compactMap { $0 as? NSButton }
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
        #expect(button.isEnabled)

        try FileManager.default.removeItem(at: session.appendingPathComponent("transcript.json"))
        try Data("# Meeting\n".utf8).write(to: session.appendingPathComponent("transcript.md"))
        window.show()
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

    @MainActor
    private func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
