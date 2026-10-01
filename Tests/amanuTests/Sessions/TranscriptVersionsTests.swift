import AppKit
import Foundation
import Testing
@testable import amanu

@Suite(.serialized, .freshHome(config: #"{"offline_echo_cancellation":false,"keep_audio":true,"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct TranscriptVersionsTests {
    private func first(_ dir: URL) throws {
        try Transcript(engine: "assemblyai", model: "universal", created_at: "2026-09-28T09:00:00Z",
            segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: "First answer.")]).write(to: dir)
        try SpeakerNames(speakers: ["A": .init(name: "Alice", source: .model)]).write(to: dir)
        try Data("First summary.".utf8).write(to: dir.appendingPathComponent("summary.md"))
    }
    private func archives(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("transcripts"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    @Test("Requesting another engine keeps the completed transcript, names and summary readable")
    @MainActor func pendingPreservesCurrent() throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        #expect(RecordingsWindow.markForRetranscription(dir, engine: "whisper") == nil)
        #expect(PostProcessor.readTranscript(dir)?.engine == "assemblyai")
        #expect(SpeakerNames.read(from: dir)?.name(for: "A") == "Alice")
        #expect(PostProcessor.hasCurrentSummary(dir))
        #expect(SessionInventory.item(for: dir)?.transcript == .pending)
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).map { $0.resolvingSymlinksInPath().path } == [dir.resolvingSymlinksInPath().path])
        #expect(PostProcessor.outstanding(dir, policy: .init(names: true, summary: true)).isEmpty)
    }

    @Test("A failed retry leaves the first result and its summary intact and reports the new attempt")
    @MainActor func failurePreservesCurrent() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        RecordingsWindow.markForRetranscription(dir, engine: "whisper")
        let broken = FakeEngine("whisper", answer: { _, _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: (any Error).self) {
            try await TranscriptionCoordinator(engine: broken, onStop: { nil }).transcribeNow(dir)
        }
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "First answer.")
        #expect(PostProcessor.hasCurrentSummary(dir))
        #expect(SessionInventory.item(for: dir)?.transcript == .deferred)
    }

    @Test("Successful retries retain independent results even when the same engine is run again")
    @MainActor func repeatedEnginesHaveTheirOwnArtifacts() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        for number in 2...3 {
            RecordingsWindow.markForRetranscription(dir, engine: "whisper")
            let engine = FakeEngine("whisper", input: .mixed, answer: { _, _ in
                [.init(start: 0, end: 1, text: "Answer \(number).", speaker: "B")]
            })
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
            try Data("Summary \(number).".utf8).write(to: dir.appendingPathComponent("summary.md"))
            SessionState.update(dir, with: [SessionState.Key.summaryStale: nil])
        }
        let previous = archives(dir)
        #expect(previous.count == 2)
        let original = try #require(previous.first { PostProcessor.readTranscript($0)?.engine == "assemblyai" })
        #expect(SpeakerNames.read(from: original)?.name(for: "A") == "Alice")
        #expect(try String(contentsOf: original.appendingPathComponent("summary.md"), encoding: .utf8) == "First summary.")
        PostProcessor.rename("A", to: "Alicia", in: original)
        #expect(SpeakerNames.read(from: original)?.name(for: "A") == "Alicia")
        #expect(SpeakerNames.read(from: dir)?.speakers["A"] == nil)
        #expect(try String(contentsOf: original.appendingPathComponent("transcript.md"), encoding: .utf8).hasPrefix("# meeting\n"))
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "Answer 3.")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcribe.requested").path))
    }

    @Test("Identical answers from consecutive runs remain separate versions")
    @MainActor func identicalAnswersAreSeparate() async throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        for _ in 0..<3 {
            RecordingsWindow.markForRetranscription(dir, engine: "whisper")
            let engine = FakeEngine("whisper", input: .mixed, answer: { _, _ in
                [.init(start: 0, end: 1, text: "Same words.")]
            })
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(TranscriptVersions.read(dir).filter { !$0.isRequest }.count == 4)
        let window = RecordingsWindow(root: recordings.root)
        let selector = try #require(window.view?.allDescendants.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "transcript-versions" })
        #expect(selector.numberOfItems == 4)
        withExtendedLifetime(window) {}
    }

    @Test("An interrupted snapshot is deduplicated and malformed versions do not hide healthy ones")
    func interruptedSnapshot() throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        let one = try TranscriptVersions.archiveCurrent(dir)
        #expect(try TranscriptVersions.archiveCurrent(dir)?.lastPathComponent == one?.lastPathComponent)
        let broken = dir.appendingPathComponent("transcripts/broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: broken.appendingPathComponent("transcript.json"))
        #expect(TranscriptVersions.read(dir).count == 1)
    }

    @Test("An unwritable archive fails before replacing any result")
    func archiveFailureKeepsCurrent() throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        try first(dir)
        #expect(PostProcessor.markForRetranscription(dir))
        try Data("blocked".utf8).write(to: dir.appendingPathComponent("transcripts"))
        #expect(throws: (any Error).self) {
            try TranscriptVersions.commit(Transcript(engine: "whisper", model: "v3", created_at: "2026-09-28T10:00:00Z", segments: []), to: dir)
        }
        #expect(PostProcessor.readTranscript(dir)?.engine == "assemblyai")
        #expect(SpeakerNames.read(from: dir)?.name(for: "A") == "Alice")
        #expect(PostProcessor.hasCurrentSummary(dir))
        #expect(TranscriptVersions.isRequested(dir))
    }

    @Test("The versions selector switches transcript, participants and summary together")
    @MainActor func previewsFollowVariant() throws {
        let recordings = try TestRecordings(); defer { recordings.remove() }
        let dir = try recordings.session("meeting")
        let old = dir.appendingPathComponent("transcripts/old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try first(old)
        try Transcript(engine: "whisper", model: "large-v3", created_at: "2026-09-28T10:00:00Z",
            segments: [.init(speaker: "B", start_ms: 0, end_ms: 1000, text: "Second answer.")]).write(to: dir)
        try Data("Second summary.".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let window = RecordingsWindow(root: recordings.root)
        let views = try #require(window.view).allDescendants
        let selector = try #require(views.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "transcript-versions" })
        #expect(selector.numberOfItems == 2)
        selector.selectItem(at: 0)
        selector.sendAction(selector.action, to: selector.target)
        let tabs = try #require(views.compactMap { $0 as? NSTabView }.first)
        func text(_ id: String) -> String? {
            tabs.tabViewItems.first { $0.identifier as? String == id }?.view?.allDescendants.compactMap { $0 as? NSTextView }.first?.string
        }
        #expect(text("transcript")?.contains("First answer.") == true)
        #expect(text("summary") == "First summary.")
        tabs.selectTabViewItem(withIdentifier: "speakers")
        #expect(tabs.selectedTabViewItem?.view?.allDescendants.compactMap { $0 as? NSTextField }.contains { $0.isEditable && $0.stringValue == "Alice" } == true)
        selector.selectItem(at: 1)
        selector.sendAction(selector.action, to: selector.target)
        #expect(text("transcript")?.contains("Second answer.") == true)
        #expect(text("summary") == "Second summary.")
        withExtendedLifetime(window) {}
    }
}
