import AVFoundation
import Foundation
import Testing

@testable import amanu

/// `amanu transcribe` from the inside: a file in, its text out, and what is
/// left in the recordings folder afterwards.
///
/// The route is the importer and the coordinator the app already runs, so
/// most of what is worth checking is at the seams — that a session made for
/// a file owes no names and no summary to anyone, that the same file a second
/// time never reaches the model, and that a session the menu imported is not
/// re-decided by a command that happened to be given the same file.
struct TranscribeCommandTests {
    /// An engine that hears nothing and answers the same two lines every
    /// time, counting how often it was asked.
    private actor LineEngine: TranscriptionEngine {
        nonisolated let name = "fake"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput = .perTrack
        private(set) var calls = 0

        func prepare() async throws {}
        func release() async {}
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            calls += 1
            return [
                .init(start: 0, end: 1.2, text: "Раз, два, три."),
                .init(start: 1.2, end: 2, text: "Проверка связи."),
            ]
        }
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let source: URL
        let engine: LineEngine

        func transcriber(summary: Bool = false) -> FileTranscriber {
            FileTranscriber(
                importer: MediaImportCoordinator(root: root),
                transcription: TranscriptionCoordinator(engine: engine, onStop: { nil }),
                summary: summary,
                transcriptionEnabled: true,
                report: { _ in })
        }
    }

    /// A quarter second of tone as `voice-note.wav`, with an empty recordings
    /// folder beside it.
    private static func fixture(_ name: String) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-transcribe-\(name)-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("voice-note.wav")
        try tone(source, seconds: 0.25)
        return Fixture(base: base, root: root, source: source, engine: LineEngine())
    }

    private static func tone(_ url: URL, seconds: Double) throws {
        let rate = 16_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let total = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for index in 0..<total {
            buffer.floatChannelData![0][index] = 0.3 * Float(sin(2 * .pi * 440 * Double(index) / rate))
        }
        try file.write(from: buffer)
    }

    /// The temporary folder is reached through a symlink, and the importer
    /// spells a session it just made and one it found again differently.
    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    /// Naming and summarizing as they stand after giving up, so that finishing
    /// a session reaches for no language model whatever this Mac's config
    /// says — the same device the coordinator's own tests use.
    private static func retirePostProcessing(_ session: URL) {
        SessionState.update(session, with: [
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ])
    }

    @Test("A file becomes plain text, and its session owes nothing further")
    func aFileBecomesText() async throws {
        let fixture = try Self.fixture("text")
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let result = try await fixture.transcriber().transcribe(fixture.source)

        #expect(TranscriptText.render(result.transcript, as: .txt, names: result.names)
            == "Раз, два, три.\nПроверка связи.\n")
        #expect(result.session.deletingLastPathComponent().lastPathComponent == "recordings")
        #expect(SessionState.value(result.session, SessionState.Key.transcriptOnly) as? Bool == true)
        // Not owed to this run, and not to the sweep either: the policy the
        // session reads for itself says both steps are off, whatever the
        // config on this Mac enables.
        #expect(PostProcessor.Policy.configured(for: result.session)
            == PostProcessor.Policy(names: false, summary: false))
        #expect(PostProcessor.outstanding(result.session).isEmpty)
        let item = try #require(SessionInventory.item(for: result.session))
        #expect(item.transcript == .done)
        #expect(item.speakers == .off)
        #expect(item.summary == .off)
        #expect(!item.isOutstanding)
    }

    @Test("The same file a second time is rendered from the session, not run through the model")
    func aSecondRunReusesTheSession() async throws {
        let fixture = try Self.fixture("again")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let transcriber = fixture.transcriber()

        let first = try await transcriber.transcribe(fixture.source)
        let second = try await transcriber.transcribe(fixture.source)

        #expect(await fixture.engine.calls == 1)
        #expect(Self.same(second.session, first.session))
        #expect(second.transcript.segments.map(\.text) == first.transcript.segments.map(\.text))
        #expect(SessionInventory.scan(root: fixture.root).count == 1)
    }

    @Test("--summary takes the transcript-only note back, so the session is finished after all")
    func summaryLiftsTheNote() async throws {
        let fixture = try Self.fixture("summary")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = try await fixture.transcriber().transcribe(fixture.source)
        #expect(PostProcessor.Policy.configured(for: first.session)
            == PostProcessor.Policy(names: false, summary: false))
        Self.retirePostProcessing(first.session)

        let second = try await fixture.transcriber(summary: true).transcribe(fixture.source)

        #expect(Self.same(second.session, first.session))
        #expect(SessionState.value(second.session, SessionState.Key.transcriptOnly) == nil)
        #expect(PostProcessor.Policy.configured(for: second.session) == PostProcessor.Policy.configured)
        #expect(await fixture.engine.calls == 1, "lifting the note is not a reason to transcribe again")
    }

    @Test("A session the menu imported keeps the fate the menu gave it")
    func aMenuImportIsNotReDecided() async throws {
        let fixture = try Self.fixture("menu")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        // Imported the way File ▸ Import does it: a session with no note on
        // it, owed names and a summary as any meeting is.
        let imported = await MediaImportCoordinator(root: fixture.root).importFiles([fixture.source])
        let session = try #require(imported.imported.first?.session)
        Self.retirePostProcessing(session)

        let result = try await fixture.transcriber().transcribe(fixture.source)

        #expect(Self.same(result.session, session))
        #expect(SessionState.value(session, SessionState.Key.transcriptOnly) == nil)
        #expect(result.transcript.segments.count == 2)
    }

    @Test("A file with no audio in it is refused in the importer's words and leaves nothing behind")
    func aFileWithoutAudioIsRefused() async throws {
        let fixture = try Self.fixture("no-audio")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let notes = fixture.base.appendingPathComponent("notes.m4a")
        try Data("not audio at all".utf8).write(to: notes)

        await #expect(throws: FileTranscriber.Refused.self) {
            try await fixture.transcriber().transcribe(notes)
        }
        #expect(await fixture.engine.calls == 0)
        #expect(SessionInventory.scan(root: fixture.root).isEmpty)
    }

    @Test("Text goes beside its source under the source's own name, or into the folder asked for")
    func outputsAreNamedAfterTheSource() {
        let talk = URL(fileURLWithPath: "/Users/anna/Movies/talk.mp4")

        #expect(TranscribeFile.destination(for: talk, format: .srt, in: nil).path
            == "/Users/anna/Movies/talk.srt")
        #expect(TranscribeFile.destination(
            for: talk, format: .txt, in: URL(fileURLWithPath: "/tmp/out", isDirectory: true)).path
            == "/tmp/out/talk.txt")
    }
}
