import Foundation
import Testing

@testable import amanu

struct TranscriptTests {
    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func transcript(createdAt: String = "2026-09-22T10:00:00Z") -> Transcript {
        Transcript(engine: "test", model: "test", created_at: createdAt, segments: [
            .init(speaker: "them", start_ms: 0, end_ms: 1000, text: "A test sentence.")
        ])
    }

    @Test("Transcripts from separate sessions keep their identity when copied together")
    func distinctFilenames() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [
            "2026.09.21-1527 Weekly sync",
            "2026.09.21-1527 Weekly sync-2",
            "2026.09.21-1540 Обсуждение",
        ]
        let filenames = [
            "transcript_2026.09.21-1527 Weekly sync.md",
            "transcript_2026.09.21-1527 Weekly sync-2.md",
            "transcript_2026.09.21-1540 Обсуждение.md",
        ]
        for (session, filename) in zip(sessions, filenames) {
            let dir = root.appendingPathComponent(session, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try transcript().write(to: dir)
            let markdown = dir.appendingPathComponent(filename)
            #expect(FileManager.default.fileExists(atPath: markdown.path))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
            try FileManager.default.copyItem(at: markdown, to: root.appendingPathComponent(filename))
            #expect(try String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8)
                .contains("# \(session)"))
        }
    }

    @Test("Long session names still produce writable, distinct transcript filenames")
    func longFilenames() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = "2026.09.21-1527 " + String(repeating: "é", count: 115)
        for suffix in ["A", "B"] {
            let dir = root.appendingPathComponent(prefix + suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try transcript().write(to: dir)
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let markdown = try #require(files.first { $0.pathExtension == "md" })
            #expect(markdown.lastPathComponent.utf8.count <= 255)
            #expect(markdown.lastPathComponent.hasPrefix("transcript_2026.09.21-1527 "))
            try transcript(createdAt: "2026-09-23T11:00:00Z").write(to: dir)
            try FileManager.default.copyItem(at: markdown, to: root.appendingPathComponent(markdown.lastPathComponent))
            PostProcessor.markForRetranscription(dir)
            #expect(!FileManager.default.fileExists(atPath: markdown.path))
        }
    }

    @Test("Re-rendering and re-transcribing update the same dated Markdown file")
    func stableFilename() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.21-1527 Weekly sync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try transcript().write(to: dir)
        let json = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        PostProcessor.rename("them", to: "Alex", in: dir)
        let markdown = dir.appendingPathComponent("transcript_2026.09.21-1527 Weekly sync.md")
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains("Alex:"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == json)

        PostProcessor.markForRetranscription(dir)
        #expect(!FileManager.default.fileExists(atPath: markdown.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        try transcript(createdAt: "2026-09-23T11:00:00Z").write(to: dir)
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains("them:"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.filter { $0.hasSuffix(".md") } == [markdown.lastPathComponent])
    }

    @Test("Naming speakers in a legacy session updates its existing Markdown file")
    func legacyMarkdownIsPreserved() throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(transcript()).write(to: dir.appendingPathComponent("transcript.json"))
        try Data("old transcript".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        PostProcessor.rename("them", to: "Alex", in: dir)
        #expect(try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
            .contains("Alex:"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.filter { $0.hasSuffix(".md") } == ["transcript.md"])
    }

    @Test("Re-transcription clears both supported transcript names and keeps other Markdown")
    func cleanupIsLimitedToTranscripts() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.21-1527", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for filename in ["transcript.md", "transcript_2026.09.21-1527.md", "notes.md"] {
            try Data("existing content".utf8).write(to: dir.appendingPathComponent(filename))
        }
        PostProcessor.markForRetranscription(dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }
            == ["notes.md"])
    }

    @Test("A failed dated Markdown write leaves the session pending")
    func failedDatedMarkdownWrite() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.21-1527", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("transcript_2026.09.21-1527.md", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try transcript().write(to: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
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
