import Foundation
import Testing

@testable import amanu

/// What the list says about a folder, and what the sweep decides to do with
/// it. Both read the same three facts — which files exist, and what the
/// session wrote about its own failures — so these tests are mostly about the
/// difference between "hasn't happened yet" and "will never happen".
struct SessionInventoryTests {
    private static let allPostProcessing = PostProcessor.Policy(names: true, summary: true)

    /// A finished session on disk, with whatever extras a test asks for.
    private static func session(
        transcript: Bool = true,
        speakers: Bool = false,
        summary: Bool = false,
        state: [String: String] = [:]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var meta: [String: Any] = [
            "started": "2026-08-18T09:00:00Z",
            "duration_seconds": 1800,
            "title": "Integration sync",
            "trigger": "mic-activity",
        ]
        for (key, value) in state { meta[key] = value }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))

        if transcript {
            let json = Transcript(
                engine: "parakeet", model: "v3", created_at: "2026-08-18T09:31:00Z",
                segments: [
                    .init(speaker: "me", start_ms: 0, end_ms: 2000, text: "Привет."),
                    .init(speaker: "them A", start_ms: 2000, end_ms: 4000, text: "Привет!"),
                ]
            )
            try JSONEncoder().encode(json)
                .write(to: dir.appendingPathComponent("transcript.json"))
        }
        if speakers {
            try SpeakerNames(
                speakers: ["them A": .init(name: "Фёдор", source: .model)]
            ).write(to: dir)
        }
        if summary {
            try Data("# notes\n".utf8).write(to: dir.appendingPathComponent("summary.md"))
        }
        return dir
    }

    /// The importer stages in a hidden folder with a meta.json already in
    /// it. The queue left those alone; the list and the sweep did not, so a
    /// half-finished import was listed and could be summarized from its
    /// staging directory.
    @Test("Hidden folders are not sessions to the list, the queue or the sweep")
    func hiddenFoldersAreNotSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["2026-09-28 10-00", ".import-1234"] {
            let made = try Self.session()
            try FileManager.default.moveItem(at: made, to: root.appendingPathComponent(name))
        }

        #expect(SessionInventory.scan(root: root).map(\.name) == ["2026-09-28 10-00"])
        #expect(SessionInventory.sessionFolders(in: root).map(\.lastPathComponent)
            == ["2026-09-28 10-00"])

        let model = FakeModel.working("claude-cli")
        let home = Home.withModels([model])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["user_name": "Самат"])
        await Home.$scoped.withValue(home) { await PostProcessor.sweep(root: root) }

        let staged = root.appendingPathComponent(".import-1234")
        #expect(!FileManager.default.fileExists(
            atPath: staged.appendingPathComponent("summary.md").path),
            "the sweep summarized a staging folder")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("2026-09-28 10-00/summary.md").path))
    }

    @Test("A session with everything done has nothing outstanding")
    func finishedSessionIsQuiet() throws {
        let dir = try Self.session(speakers: true, summary: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir))
        #expect(item.transcript == .done)
        #expect(item.speakers == .done)
        #expect(item.summary == .done)
        #expect(!item.isOutstanding)
        #expect(PostProcessor.outstanding(dir).isEmpty)
    }

    @Test("A transcribed session with no names or summary owes both")
    func freshTranscriptOwesBoth() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir, policy: Self.allPostProcessing))
        #expect(item.speakers == .pending)
        #expect(item.summary == .pending)
        #expect(PostProcessor.outstanding(dir, policy: Self.allPostProcessing)
            == .init(names: true, summary: true))
    }

    /// The distinction the whole deferral mechanism exists for: deferred work
    /// comes back, failed work doesn't.
    @Test("Deferred work is still owed; failed work is not")
    func deferredComesBackFailedDoesNot() throws {
        let deferred = try Self.session(state: [
            SessionState.Key.speakersStatus: SessionState.deferred,
            SessionState.Key.summaryStatus: SessionState.deferred,
        ])
        let failed = try Self.session(state: [
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed: every backend refused",
        ])
        defer {
            try? FileManager.default.removeItem(at: deferred)
            try? FileManager.default.removeItem(at: failed)
        }

        #expect(SessionInventory.item(for: deferred, policy: Self.allPostProcessing)?.speakers
            == .deferred)
        #expect(PostProcessor.outstanding(deferred, policy: Self.allPostProcessing)
            == .init(names: true, summary: true))

        #expect(SessionInventory.item(for: failed, policy: Self.allPostProcessing)?.isOutstanding
            == false)
        #expect(PostProcessor.outstanding(failed, policy: Self.allPostProcessing).isEmpty)
    }

    @Test("A retired session shows why, and is owed nothing until re-queued")
    func retiredSessionExplainsItself() throws {
        let dir = try Self.session(transcript: false, state: [
            SessionState.Key.transcriptionFailed: "assemblyai returned no speech",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(SessionInventory.item(for: dir))
        #expect(item.transcript == .failed("assemblyai returned no speech"))
        // Nothing to name or summarize without a transcript — and crucially,
        // no post-processing attempt that could burn its way to "failed".
        #expect(PostProcessor.outstanding(dir).isEmpty)
    }

    @Test("Re-transcribing clears failure marks and retains the completed files")
    func retranscribeResetsTheSession() throws {
        let dir = try Self.session(speakers: true, summary: true, state: [
            SessionState.Key.transcriptionFailed: "timed out",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        PostProcessor.markForRetranscription(dir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(SpeakerNames.file).path))
        #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
        #expect(SessionInventory.item(for: dir)?.transcript == .pending)
    }

    // MARK: - naming by hand

    @Test("A name typed by hand survives a later automatic pass")
    func manualNamesOutrankTheModel() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }

        PostProcessor.rename("them A", to: "Фёдор", in: dir)
        let byHand = try #require(SpeakerNames.read(from: dir))
        #expect(byHand.speakers["them A"]?.source == .manual)

        // What a fresh pass would produce, merged in the way SpeakerNamer does.
        var fresh = SpeakerNames()
        fresh.speakers["them A"] = .init(name: "Пётр", source: .model, confidence: "high")
        fresh.speakers["me"] = .init(name: "Samat Galimov", source: .account)
        let merged = byHand.merged(with: fresh)

        #expect(merged.speakers["them A"]?.name == "Фёдор")
        #expect(merged.speakers["me"]?.name == "Samat Galimov")
    }

    @Test("Naming re-renders the readable transcript but never the canonical one")
    func namingLeavesTheJSONAlone() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        PostProcessor.rename("them A", to: "Фёдор", in: dir)
        let after = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        #expect(before == after)

        let markdown = try String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8
        )
        #expect(markdown.contains("Фёдор:"))
        #expect(markdown.contains("them A → Фёдор"))
        // "me" was never named, so it prints as itself rather than as a guess.
        #expect(markdown.contains("me:"))
    }

    @Test("Clearing a name by hand puts the label back")
    func clearingANameRestoresTheLabel() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }

        PostProcessor.rename("them A", to: "Фёдор", in: dir)
        PostProcessor.rename("them A", to: "", in: dir)

        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == nil)
        let markdown = try String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8
        )
        #expect(markdown.contains("them A:"))
        #expect(!markdown.contains("Фёдор"))
    }

}
