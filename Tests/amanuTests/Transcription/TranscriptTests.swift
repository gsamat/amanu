import Foundation
import Testing

@testable import amanu

struct TranscriptTests {
    @Test("Bulk formatting skips transcripts from other recognizers")
    func bulkFormattingSkipsOtherEngines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-format-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-09-23T00:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")]
        )
        try transcript.write(to: session)
        let markdownURL = session.appendingPathComponent("transcript.md")
        try Data("original markdown".utf8).write(to: markdownURL)

        #expect(try FormatTranscripts.reformat(in: root).isEmpty)
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "original markdown")
    }

    @Test("Other recognizers retain their original Markdown segment boundaries")
    func leavesNonAssemblyAISegmentsSeparate() {
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-09-23T00:00:00Z",
            segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 900, text: "Добрый"),
                .init(speaker: "me", start_ms: 1000, end_ms: 1300, text: "день."),
            ])

        let markdown = transcript.rendered(title: "Встреча", names: nil)

        #expect(markdown.contains("**[0:00] me:** Добрый\n\n"))
        #expect(markdown.contains("**[0:01] me:** день."))
        #expect(!markdown.contains("Добрый день."))
    }

    @Test("Existing Markdown can be reformatted from its canonical transcript")
    func reformatsExistingTranscriptWithoutChangingJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-format-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-23T00:00:00Z",
            segments: [
                .init(speaker: "them", start_ms: 0, end_ms: 250, text: "Добрый"),
                .init(speaker: "them", start_ms: 250, end_ms: 600, text: "день."),
            ])
        try transcript.write(to: session)
        let json = try Data(contentsOf: session.appendingPathComponent("transcript.json"))
        try Data("old word-per-line markdown".utf8).write(
            to: session.appendingPathComponent("transcript.md"))

        let changed = try FormatTranscripts.reformat(in: root)

        #expect(changed.count == 1)
        #expect(changed.first?.lastPathComponent == "meeting")
        let markdown = try String(contentsOf: session.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("**[0:00] them:** Добрый день."))
        #expect(try Data(contentsOf: session.appendingPathComponent("transcript.json")) == json)
        #expect(try FormatTranscripts.reformat(in: root).isEmpty)
    }

    @Test("Word-sized segments form readable speaker turns")
    func rendersContinuousSpeechAsOneParagraph() {
        let transcript = Transcript(
            engine: "assemblyai",
            model: "test-model",
            created_at: "2026-09-23T00:00:00Z",
            segments: [
                .init(speaker: "them A", start_ms: 0, end_ms: 300, text: "Привет,"),
                .init(speaker: "me", start_ms: 200, end_ms: 400, text: "Да."),
                .init(speaker: "them A", start_ms: 300, end_ms: 600, text: "Андрей."),
                .init(speaker: "them A", start_ms: 2400, end_ms: 2700, text: "Как"),
                .init(speaker: "them A", start_ms: 2700, end_ms: 3100, text: "дела?"),
            ]
        )

        let markdown = transcript.rendered(title: "Встреча", names: nil)
        #expect(markdown.contains("**[0:00] them A:** Привет, Андрей."))
        #expect(markdown.contains("**[0:00] me:** Да."))
        #expect(markdown.contains("**[0:02] them A:** Как дела?"))
        #expect(!markdown.contains("**[0:00] them A:** Андрей."))
        #expect(!markdown.contains("**[0:02] them A:** дела?"))
    }

    @Test("Two speaker labels named as one person keep their word order")
    func groupsByNamedPersonInChronologicalOrder() {
        let transcript = Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-23T00:00:00Z",
            segments: [
                .init(speaker: "them A", start_ms: 0, end_ms: 250, text: "Я"),
                .init(speaker: "them B", start_ms: 250, end_ms: 500, text: "сам"),
                .init(speaker: "them A", start_ms: 500, end_ms: 800, text: "сделаю."),
            ])
        let names = SpeakerNames(speakers: [
            "them A": .init(name: "Фёдор", source: .manual),
            "them B": .init(name: "Фёдор", source: .manual),
        ])

        let markdown = transcript.rendered(title: "Встреча", names: names)

        #expect(markdown.contains("**[0:00] Фёдор:** Я сам сделаю."))
        #expect(!markdown.contains("**[0:00] Фёдор:** сам"))
    }

    @Test("A failed Markdown write does not leave the completion marker")
    func failedMarkdownWriteDoesNotLeaveCompletionMarker() throws {
        let fileManager = FileManager.default
        let session = fileManager.temporaryDirectory
            .appendingPathComponent("amanu-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: session) }

        // A directory where transcript.md should go: the write fails, and the
        // session must stay pending rather than being retired half-written.
        try fileManager.createDirectory(
            at: session.appendingPathComponent("transcript.md", isDirectory: true),
            withIntermediateDirectories: true
        )

        let transcript = Transcript(
            engine: "parakeet",
            model: "test-model",
            created_at: "2026-07-28T00:00:00Z",
            segments: []
        )

        do {
            try transcript.write(to: session)
            Issue.record("Expected writing transcript.md over a directory to fail.")
        } catch {
            // Expected: transcript.md is a directory.
        }

        let completionMarker = session.appendingPathComponent("transcript.json")
        #expect(
            fileManager.fileExists(atPath: completionMarker.path) == false,
            "A failed transcript.md write must leave the session pending."
        )
    }
}
