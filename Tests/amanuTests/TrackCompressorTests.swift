import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Compression deletes audio, which makes it the most dangerous code in the
/// program. These tests are about the order of operations: nothing may be
/// deleted before something readable has taken its place, and meta.json must
/// never point at a file that isn't there.
struct TrackCompressorTests {
    private func writePCM(
        _ url: URL,
        seconds: Double,
        frequency: Double,
        leadingSilence: Double = 0
    ) throws {
        let rate = 48000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let chunk = AVAudioFrameCount(4800)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let n = min(Int(chunk), total - written)
            buffer.frameLength = AVAudioFrameCount(n)
            let data = buffer.floatChannelData![0]
            for i in 0..<n {
                let frame = written + i
                data[i] = Double(frame) / rate < leadingSilence
                    ? 0
                    : 0.45 * Float(sin(2 * .pi * frequency * Double(frame) / rate))
            }
            try file.write(from: buffer)
            written += n
        }
    }

    private func makeTwoTrackSession() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-stereo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePCM(dir.appendingPathComponent("mic.caf"), seconds: 3, frequency: 220)
        try writePCM(dir.appendingPathComponent("system.caf"), seconds: 2, frequency: 660)
        try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 500],
            "duration_seconds": 3,
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private func peak(
        in url: URL,
        channel: Int,
        from start: Double,
        to end: Double
    ) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let first = AVAudioFramePosition(start * format.sampleRate)
        let frames = AVAudioFrameCount((end - start) * format.sampleRate)
        guard first < file.length,
              channel < Int(format.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return 0 }
        file.framePosition = first
        try file.read(into: buffer, frameCount: frames)
        guard let samples = buffer.floatChannelData?[channel] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) {
            max($0, abs(samples[$1]))
        }
    }

    /// Catches a regression back to one compressed file per source track, or
    /// a stereo file whose channels were accidentally swapped or mixed.
    @Test("Kept audio becomes one stereo archive with mic left and system right")
    func keptAudioBecomesOneStereoArchive() throws {
        let dir = try makeTwoTrackSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("derived".utf8).write(
            to: dir.appendingPathComponent("multichannel.m4a"))
        try Data("partial".utf8).write(
            to: dir.appendingPathComponent("multichannel.tmp.m4a"))
        let sourceBytes = try ["mic.caf", "system.caf"].reduce(Int64(0)) { total, name in
            total + (try #require(
                (try FileManager.default.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path))[.size] as? Int64))
        }

        TrackCompressor.compress(sessionDir: dir)

        let archive = dir.appendingPathComponent("audio.m4a")
        let meta = try meta(in: dir)
        let files = try #require(meta["files"] as? [String: String])
        let channels = try #require(meta["audio_channels"] as? [String: Int])
        #expect(files == ["mic": "audio.m4a", "system": "audio.m4a"])
        #expect(channels == ["mic": 0, "system": 1])
        #expect(FileManager.default.fileExists(atPath: archive.path))
        let archivedFile = try AVAudioFile(forReading: archive)
        #expect(archivedFile.processingFormat.channelCount == 2)
        let duration = Double(archivedFile.length) / archivedFile.processingFormat.sampleRate
        #expect(duration >= 2.99 && duration < 3.2, "expected ~3 seconds, got \(duration)")
        let archiveBytes = try #require(
            (try FileManager.default.attributesOfItem(atPath: archive.path))[.size] as? Int64)
        #expect(archiveBytes < sourceBytes / 2,
                "expected compressed audio, got \(sourceBytes) → \(archiveBytes)")
        #expect(try peak(in: archive, channel: 0, from: 0.7, to: 1.2) > 0.2)
        #expect(try peak(in: archive, channel: 1, from: 0.0, to: 0.4) < 0.02)
        #expect(try peak(in: archive, channel: 1, from: 0.7, to: 1.2) > 0.2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("multichannel.m4a").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("multichannel.tmp.m4a").path))
    }

    /// Catches handing the full stereo archive to a per-track transcription
    /// engine twice instead of isolating the logical mic/system tracks.
    @Test("Archive channels can be materialized independently")
    func archiveChannelsCanBeMaterialized() throws {
        let dir = try makeTwoTrackSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        TrackCompressor.compress(sessionDir: dir)

        let archive = dir.appendingPathComponent("audio.m4a")
        let mic = dir.appendingPathComponent("extracted-mic.m4a")
        let system = dir.appendingPathComponent("extracted-system.m4a")
        try AudioChannelExtractor.extract(channel: 0, from: archive, to: mic)
        try AudioChannelExtractor.extract(channel: 1, from: archive, to: system)

        #expect(try AVAudioFile(forReading: mic).processingFormat.channelCount == 1)
        #expect(try AVAudioFile(forReading: system).processingFormat.channelCount == 1)
        #expect(try peak(in: mic, channel: 0, from: 0.7, to: 1.2) > 0.2)
        #expect(try peak(in: system, channel: 0, from: 0.0, to: 0.4) < 0.02)
        #expect(try peak(in: system, channel: 0, from: 0.7, to: 1.2) > 0.2)
    }

    /// Catches a retranscription settlement treating the already archived
    /// file as two separate sources and replacing both channels with a mix.
    @Test("Settling an existing stereo archive is idempotent")
    func existingArchiveIsNotRecompressed() throws {
        let dir = try makeTwoTrackSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        TrackCompressor.compress(sessionDir: dir)
        TrackCompressor.compress(sessionDir: dir)

        let archive = dir.appendingPathComponent("audio.m4a")
        #expect(try peak(in: archive, channel: 0, from: 0.7, to: 1.2) > 0.2)
        #expect(try peak(in: archive, channel: 1, from: 0.0, to: 0.4) < 0.02)
        #expect(try peak(in: archive, channel: 1, from: 0.7, to: 1.2) > 0.2)
    }

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
        try Data("stereo".utf8).write(to: dir.appendingPathComponent("multichannel.m4a"))
        try Data("partial".utf8).write(to: dir.appendingPathComponent("multichannel.tmp.m4a"))
        try Data("archive".utf8).write(to: dir.appendingPathComponent("audio.m4a"))

        TrackCompressor.discard(sessionDir: dir)

        for name in [
            "mic.caf", "mic.m4a", "mixed.m4a", "multichannel.m4a",
            "multichannel.tmp.m4a", "audio.m4a",
        ] {
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
