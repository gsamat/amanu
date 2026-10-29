import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Where a long meeting is cut, and what its pieces are sent with — against
/// real audio files and a stub of the API, so the whole path a meeting over
/// five minutes takes runs without a key or a network.
struct SlicedTranscriptionTests {
    /// A tone with two seconds of silence at each of `gaps`.
    private static func speech(seconds: Double, gaps: [Double], in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("mixed.caf")
        try TestAudio.write(to: url, seconds: seconds) { _, frame in
            let t = Double(frame) / 48_000
            return gaps.contains { t >= $0 && t < $0 + 2 } ? 0 : 0.3 * Float(sin(2 * .pi * 220 * t))
        }
        return url
    }

    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-sliced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stream(_ speakers: [String], done: Bool = true) -> String {
        speakers.enumerated().map { index, speaker in
            #"data: {"type":"transcript.text.segment","text":"x","speaker":"\#(speaker)","start":\#(index * 4),"end":\#(index * 4 + 3)}"# + "\n\n"
        }.joined() + (done ? "data: {\"type\":\"transcript.text.done\",\"text\":\"x\"}\n\ndata: [DONE]\n\n" : "")
    }

    @Test("Each cut lands in the last pause before the limit")
    func cutsFindThePause() {
        // 150 seconds at 100 ms, quiet only at 40–42 s, 55–57 s and 110–112 s.
        var levels = [Float](repeating: 0.3, count: 1500)
        for gap in [400, 550, 1100] { for index in gap..<gap + 20 { levels[index] = 0 } }

        let cuts = AudioSlicer.cuts(levels: levels, bucket: 0.1, every: 60, window: 30)
        #expect(cuts.count == 2)
        #expect((55...57).contains(cuts[0]))
        #expect((110...112).contains(cuts[1]))
    }

    @Test("Without a pause, each cut lands at the limit")
    func cutsWithoutPause() {
        let cuts = AudioSlicer.cuts(
            levels: [Float](repeating: 0.3, count: 3000), bucket: 0.1, every: 130, window: 30)
        #expect(cuts.map { $0.rounded() } == [130, 260])
        #expect(AudioSlicer.cuts(levels: [0.3, 0.3], bucket: 0.1, every: 60, window: 30).isEmpty)
    }

    @Test("A voice sample is a 16 kHz mono WAV of the asked-for length")
    func clip() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try AudioClip.wav(
            from: try Self.speech(seconds: 20, gaps: [], in: dir), start: 5, length: 3)
        let url = dir.appendingPathComponent("clip.wav")
        try wav.write(to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) - 48_000) < 1_000)
    }

    /// The whole path: cut, the first piece ahead, the rest told about its
    /// voices, labels put back on one clock.
    @Test("A long meeting is sent in pieces whose speakers carry over")
    func slicedMeeting() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try Self.speech(seconds: 150, gaps: [55, 110], in: dir)

        let stub = StubHTTP { _, count in
            .json(200, count == 1 ? Self.stream(["A"]) : Self.stream(["1A", "B"]))
        }
        let engine = try OpenAITranscriptionEngine(
            durationLimit: 60, apiKey: "test-key", session: stub.session, retry: .once)
        let segments = try await engine.transcribe(audio)

        #expect(stub.requests.count == 3)
        #expect(segments.map(\.speaker) == ["1A", "1A", "2B", "1A", "3B"])
        // The second piece starts in the first pause, the third in the second.
        #expect((55...57).contains(segments[1].start))
        #expect((110...112).contains(segments[3].start))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("openai-slices").path))
    }

    /// One piece in thirty came back with its segments and no closing event.
    @Test("A piece whose answer stops short is asked for again, three times at most")
    func truncatedPiece() async throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try Self.speech(seconds: 100, gaps: [48], in: dir)

        let retried = StubHTTP { _, count in .json(200, Self.stream(["A"], done: count != 2)) }
        let segments = try await OpenAITranscriptionEngine(
            durationLimit: 60, apiKey: "test-key", session: retried.session, retry: .once
        ).transcribe(audio)
        #expect(retried.requests.count == 3)
        #expect(segments.map(\.speaker) == ["1A", "2A"])

        let never = StubHTTP { _, _ in .json(200, Self.stream(["A"], done: false)) }
        let engine = try OpenAITranscriptionEngine(
            apiKey: "test-key", session: never.session, retry: .once)
        await #expect(throws: CloudHTTP.Failure.self) { try await engine.transcribe(audio) }
        #expect(never.requests.count == OpenAITranscriptionEngine.streamAttempts)
    }
}
