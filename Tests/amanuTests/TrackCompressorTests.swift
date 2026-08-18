import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Compression deletes audio, which makes it the most dangerous code in the
/// program. These tests are about the order of operations: nothing may be
/// deleted before something readable has taken its place, and meta.json must
/// never point at a file that isn't there.
struct TrackCompressorTests {
    /// A session folder with one PCM track of `seconds` and a meta.json
    /// pointing at it, shaped exactly as RecordingSession writes them.
    private func makeSession(seconds: Double = 2, channels: AVAudioChannelCount = 1) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-compress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let rate = 48000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: channels, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: dir.appendingPathComponent("mic.caf"),
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: channels),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)

        let chunk = AVAudioFrameCount(4800)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let n = min(Int(chunk), total - written)
            buffer.frameLength = AVAudioFrameCount(n)
            for channel in 0..<Int(channels) {
                let data = buffer.floatChannelData![channel]
                for i in 0..<n {
                    data[i] = 0.4 * Float(sin(2 * .pi * 220 * Double(written + i) / rate))
                }
            }
            try file.write(from: buffer)
            written += n
        }

        try JSONSerialization
            .data(withJSONObject: [
                "files": ["mic": "mic.caf"],
                "duration_seconds": Int(seconds),
            ])
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private func meta(in dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Ten seconds rather than two: an m4a carries about 60 KB of fixed
    /// container overhead, which swamps the saving on a clip short enough to
    /// make the ratio look bad. At a minute it is 12×, at an hour more.
    @Test("Encoding produces a file that covers the whole source")
    func encodeCoversTheSource() throws {
        let dir = try makeSession(seconds: 10)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("mic.caf")
        let destination = dir.appendingPathComponent("mic.m4a")
        _ = try TrackCompressor.encode(source, to: destination)

        let original = try AVAudioFile(forReading: source)
        let encoded = try AVAudioFile(forReading: destination)
        #expect(encoded.length >= Int64(Double(original.length) * 0.99))
        // The point of the exercise: the same audio, a fraction of the bytes.
        let before = try #require(
            (try FileManager.default.attributesOfItem(atPath: source.path))[.size] as? Int64)
        let after = try #require(
            (try FileManager.default.attributesOfItem(atPath: destination.path))[.size] as? Int64)
        #expect(after < before / 4, "expected a real saving, got \(before) → \(after)")
    }

    @Test("A compressed session points at the new files and drops the old ones")
    func compressionRewritesMetaAndDeletesPCM() throws {
        // Config is read from the user's real config file; if compression is
        // switched off there, this test has nothing to assert.
        try #require(Config.compressTracks() && !Config.keepUncompressed())

        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        TrackCompressor.compress(sessionDir: dir)

        let meta = try meta(in: dir)
        #expect((meta["files"] as? [String: String])?["mic"] == "mic.m4a")
        #expect(meta["compressed"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.m4a").path))
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("mic.caf").path) == false,
            "The PCM is the whole reason to compress; it has to go.")
        // Whatever else changed, the session must still resolve to real files.
        for name in (meta["files"] as? [String: String] ?? [:]).values {
            #expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(name).path))
        }
    }

    @Test("An unreadable track is left alone rather than replaced")
    func unreadableTrackSurvives() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A track that can't be decoded — the case where encoding must fail.
        let source = dir.appendingPathComponent("mic.caf")
        try Data("not audio".utf8).write(to: source)

        TrackCompressor.compress(sessionDir: dir)

        let meta = try meta(in: dir)
        #expect(
            (meta["files"] as? [String: String])?["mic"] == "mic.caf",
            "meta.json must keep pointing at the file that exists.")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("mic.m4a").path) == false,
            "A failed encode must not leave a half-written file behind.")
    }

    @Test("Discarding removes every form of the audio and says so in meta.json")
    func discardRemovesAudio() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A session caught between compressing and rewriting meta.json has
        // both forms of the track on disk, and meta names only one of them.
        try Data("compressed".utf8).write(to: dir.appendingPathComponent("mic.m4a"))
        try Data("mixed".utf8).write(to: dir.appendingPathComponent("mixed.m4a"))

        TrackCompressor.discard(sessionDir: dir)

        for name in ["mic.caf", "mic.m4a", "mixed.m4a"] {
            #expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent(name).path) == false,
                "\(name) survived a discard.")
        }
        let meta = try meta(in: dir)
        #expect(meta["audio_discarded"] as? Bool == true)
        #expect(
            (meta["files"] as? [String: String])?["mic"] == "mic.caf",
            "meta.json is the session's account of what was recorded; that stays true.")
        #expect(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path),
            "Discarding audio must not touch anything else in the folder.")
    }

    @Test("A discarded session is not offered for transcribing again")
    func discardedSessionHasNoAudio() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(SessionInventory.item(for: dir)?.hasAudio == true)
        TrackCompressor.discard(sessionDir: dir)
        #expect(SessionInventory.item(for: dir)?.hasAudio == false)
    }

    @Test("A session with no meta.json is left untouched")
    func missingMetaIsSafe() throws {
        let dir = try makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("meta.json"))

        TrackCompressor.compress(sessionDir: dir)

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }
}
