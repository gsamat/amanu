import AVFoundation
import Foundation
import Testing

@testable import amanu

/// A side that recorded nothing is a silent side, not a broken recording.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct EmptyTrackTests {
    @Test("Parakeet rejects a CAF beyond the decoder's frame limit before loading a model")
    func oversizedTrackDoesNotReachParakeet() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let url = recordings.root.appendingPathComponent("long.caf")
        let frames = UInt64(UInt32.max) + 1
        // An ordinary mono CAF with a sparse PCM payload. Only the header occupies disk space.
        var header = Data("caff".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { header.append(contentsOf: $0) }
        }
        append(UInt16(1))
        append(UInt16(0))
        header.append(contentsOf: "desc".utf8)
        append(UInt64(32))
        append(Double(48_000).bitPattern)
        header.append(contentsOf: "lpcm".utf8)
        for field: UInt32 in [2, 2, 1, 1, 16] { append(field) }
        header.append(contentsOf: "data".utf8)
        append(frames * 2 + 4)
        append(UInt32(0))
        try header.write(to: url)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(header.count) + frames * 2)
        try file.close()
        #expect(try AVAudioFile(forReading: url).length == Int64(frames))

        do {
            _ = try await ParakeetEngine().transcribe(url)
            Issue.record("The oversized track was accepted")
        } catch let error as ParakeetEngine.EngineError {
            #expect(error.isPermanent)
            #expect(error.description.contains("long.caf"))
        }
    }

    /// Refuses a file with no frames the way Whisper and GigaAM do: as
    /// unreadable audio, which is permanent.
    private static func strictLocalEngine() -> FakeEngine {
        FakeEngine("whisper", answer: { audio, call in
            let file = try AVAudioFile(forReading: audio)
            guard file.length > 0 else { throw WhisperEngine.EngineError.unreadableAudio(audio, nil) }
            return try FakeEngine.speech(audio, call)
        })
    }

    private static func emptyTrack(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        _ = try AVAudioFile(
            forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: 48_000, channels: 1))
    }

    @Test("A track created but never written is transcribed as silence")
    func headerOnlyTrackIsSilent() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try Self.emptyTrack(dir.appendingPathComponent("system.caf"))
        let engine = Self.strictLocalEngine()

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.speaker) == ["me"])
        #expect(engine.counts.heard.map(\.lastPathComponent) == ["mic.caf"])
        #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    @Test("A zero-byte track is silence too")
    func zeroByteTrackIsSilent() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try Data().write(to: dir.appendingPathComponent("mic.caf"))

        try await TranscriptionCoordinator(engine: Self.strictLocalEngine(), onStop: { nil })
            .transcribeNow(dir)

        #expect(PostProcessor.readTranscript(dir)?.segments.map(\.speaker) == ["them"])
    }

    /// The microphone can fall back to raw capture and leave no mic.caf at
    /// all. The per-track path threw for it, so a local engine counted the
    /// session three times, retired it, and never transcribed the far end.
    @Test("A track that is not on disk is a silent side, not a failure")
    func missingTrackIsSilent() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mic.caf"))
        let engine = Self.strictLocalEngine()

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(PostProcessor.readTranscript(dir)?.segments.map(\.speaker) == ["them"])
        #expect(engine.counts.heard.map(\.lastPathComponent) == ["system.caf"])
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
    }

    @Test("With every track gone there is no recording, and that is still an error")
    func everyTrackMissingIsAnError() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mic.caf"))
        try Self.emptyTrack(dir.appendingPathComponent("system.caf"))
        let engine = Self.strictLocalEngine()

        await #expect(throws: CocoaError.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(engine.counts.heard.isEmpty)
    }

    @Test("Unreadable audio is permanent in every local engine")
    func unreadableIsPermanentEverywhere() {
        let url = URL(fileURLWithPath: "/tmp/broken.caf")
        #expect(ParakeetEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(WhisperEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(GigaAMEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(!ParakeetEngine.EngineError.notPrepared.isPermanent)
    }
}
