import Foundation
import Testing

@testable import quill

/// Folder names are the index of the whole archive: three weeks later the
/// question is never "what happened at 20:39", it's "where's that call with
/// the client". These tests pin down what ends up in the name.
@MainActor
struct SessionNamingTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The timestamp prefix is load-bearing, not decoration: the transcription
    /// queue orders pending sessions by folder name and expects that to be
    /// chronological.
    private func timestamp(_ name: String) -> String {
        String(name.prefix(15))
    }

    @Test("Title and app both land in the folder name")
    func titleAndApp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: "Integration sync", app: "zoom.us"))
        #expect(session.dir.lastPathComponent.hasSuffix("Integration sync (zoom.us)"))
        #expect(timestamp(session.dir.lastPathComponent).contains("."))
    }

    @Test("With no calendar entry, the app alone names the folder")
    func appOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(root: root, context: MeetingContext(app: "Telegram"))
        #expect(session.dir.lastPathComponent.hasSuffix(" Telegram"))
    }

    @Test("Knowing nothing still gives a valid, timestamped folder")
    func nothingKnown() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(root: root)
        #expect(session.dir.lastPathComponent.count == 15, "expected a bare timestamp")
        #expect(FileManager.default.fileExists(atPath: session.dir.path))
    }

    /// Slashes would silently create nested directories and colons show up as
    /// slashes in Finder — a meeting called "Q3: plans / budget" must not
    /// scatter the recording across three folders.
    @Test("Path separators in a meeting title can't escape the folder")
    func titleCannotEscape() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: "Q3: plans / budget\nsecond line", app: "Google Chrome"))
        let name = session.dir.lastPathComponent
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\n"))
        #expect(session.dir.deletingLastPathComponent().lastPathComponent
            == root.lastPathComponent, "the session must be a direct child of the root")
        #expect(name.contains("Q3 plans budget"))
    }

    @Test("A very long title is cut rather than left unreadable")
    func longTitleIsTrimmed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: String(repeating: "very long meeting ", count: 20),
                                    app: "zoom.us"))
        // Timestamp + 60 chars of title + " (zoom.us)", give or take a space.
        #expect(session.dir.lastPathComponent.count < 100)
        #expect(session.dir.lastPathComponent.hasSuffix("(zoom.us)"))
    }

    @Test("Two meetings in the same minute get separate folders")
    func collisionsAreSuffixed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = MeetingContext(title: "Standup", app: "zoom.us")
        let first = try RecordingSession(root: root, context: context)
        let second = try RecordingSession(root: root, context: context)
        #expect(first.dir != second.dir)
        #expect(second.dir.lastPathComponent.hasSuffix("-2"))
    }

    @Test("meta.json carries the attendees and the link, not just the name")
    func metaCarriesTheDetails() throws {
        let context = MeetingContext(
            title: "Integration sync",
            app: "zoom.us",
            attendees: ["Anna", "Boris"],
            link: "https://zoom.us/j/123")
        let fields = context.metaFields

        #expect(fields["app"] as? String == "zoom.us")
        let calendar = try #require(fields["calendar"] as? [String: Any])
        #expect(calendar["attendees"] as? [String] == ["Anna", "Boris"])
        #expect(calendar["link"] as? String == "https://zoom.us/j/123")
        #expect(calendar["title"] as? String == "Integration sync")
    }
}
