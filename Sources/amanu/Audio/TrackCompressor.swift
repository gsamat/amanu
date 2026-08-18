import AVFoundation
import Foundation

/// Settles a finished session's audio once its transcript exists: either
/// deletes it, or turns the two PCM tracks into one stereo AAC archive and
/// deletes the originals.
///
/// Recording writes uncompressed PCM because that is the only format that
/// survives a hard kill (see AudioFormats), at about a gigabyte an hour across
/// both tracks. That's a fine price for the duration of a meeting and a silly
/// one for an archive, so once the transcript exists — the thing the audio was
/// for — `keep_audio` decides whether it is archived or discarded.
///
/// Order matters and is deliberate: transcript first, then settling. A failed
/// transcription never calls this, so the only copy of a meeting is kept.
enum TrackCompressor {
    /// What becomes of a session's audio once its transcript exists: kept and
    /// compressed, or thrown away — `keep_audio` decides.
    ///
    /// The one caller that must not come through here is the failure path:
    /// a session with no transcript keeps its audio unconditionally, because
    /// that recording is the only copy of the meeting and a later attempt is
    /// all it has.
    static func settle(sessionDir dir: URL) {
        if Config.keepAudio() {
            compress(sessionDir: dir)
        } else {
            discard(sessionDir: dir)
        }
    }

    /// Delete the audio, leaving the transcript, the summary and the record of
    /// what was recorded. meta.json keeps its `files` — it is the session's
    /// account of itself, and "there was a mic track called mic.caf" stays
    /// true after the file goes — and gains `audio_discarded`, which is what
    /// stops the recordings window offering to transcribe it again.
    static func discard(sessionDir dir: URL) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }
        let fm = FileManager.default

        let named = (SessionState.read(dir)?["files"] as? [String: String]).map { Array($0.values) } ?? []
        // Both extensions for every track: a session interrupted between
        // compressing and rewriting meta.json has one of each on disk.
        var candidates = Set<String>()
        for name in named {
            candidates.insert(name)
            let stem = (name as NSString).deletingPathExtension
            candidates.insert("\(stem).caf")
            candidates.insert("\(stem).m4a")
        }
        candidates.insert("mixed.m4a")
        candidates.insert("audio.m4a")
        candidates.insert("audio.tmp.m4a")

        var freed: Int64 = 0
        var removed = 0
        for name in candidates.sorted() {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let bytes = size(of: url)
            do {
                try fm.removeItem(at: url)
                freed += bytes
                removed += 1
            } catch {
                log("couldn't delete \(name): \(error)")
            }
        }

        guard removed > 0 else { return }
        SessionState.update(dir, with: ["audio_discarded": true])
        log("audio discarded — \(mb(freed)) freed (keep_audio is off)")
    }

    /// Align the mic and system tracks on their shared clock, archive them as
    /// the left and right channels of one M4A, then delete what's been
    /// replaced. A missing track becomes a silent channel; an existing track
    /// that cannot be read aborts the operation and remains untouched.
    static func compress(sessionDir dir: URL) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }

        let metaURL = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metaURL),
            var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = meta["files"] as? [String: String]
        else {
            log("compression skipped — can't read meta.json")
            return
        }

        if files["mic"] == "audio.m4a",
           files["system"] == "audio.m4a",
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path) {
            return
        }

        let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
        let archive = dir.appendingPathComponent("audio.m4a")
        let temporary = dir.appendingPathComponent("audio.tmp.m4a")
        let mic = files["mic"].map {
            StereoTrack(url: dir.appendingPathComponent($0), offsetMs: offsets["mic"] ?? 0)
        }
        let system = files["system"].map {
            StereoTrack(url: dir.appendingPathComponent($0), offsetMs: offsets["system"] ?? 0)
        }

        let saved: String
        do {
            saved = try encodeStereo(mic: mic, system: system, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log("compression failed, keeping the originals: \(error)")
            return
        }

        do {
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: temporary, to: archive)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log("couldn't put audio.m4a in place, keeping the originals: \(error)")
            return
        }

        meta["files"] = ["mic": "audio.m4a", "system": "audio.m4a"]
        meta["audio_channels"] = ["mic": 0, "system": 1]
        if let original = meta["start_offset_ms"] {
            meta["recorded_start_offset_ms"] = original
        }
        meta["start_offset_ms"] = ["mic": 0, "system": 0]
        meta["compressed"] = true
        guard let updated = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else {
            try? FileManager.default.removeItem(at: archive)
            log("compression done but meta.json could not be rewritten — keeping the originals")
            return
        }
        // The PCM is deleted only after meta.json points somewhere else, so an
        // interruption at any point leaves a session that still resolves to
        // files that exist.
        do {
            try updated.write(to: metaURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: archive)
            log("couldn't rewrite meta.json (\(error)) — keeping the originals")
            return
        }

        for name in Set(files.values) where name != archive.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        // Derived from the tracks and regenerated on demand; keeping it costs
        // more than the tracks themselves.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("mixed.m4a"))
        log("archived mic left + system right → audio.m4a (\(saved))")
    }

    // MARK: -

    enum CompressionError: Error, CustomStringConvertible {
        case unreadable(URL)
        case tooShort(source: Int64, encoded: Int64)
        case noUsableTracks

        var description: String {
            switch self {
            case .unreadable(let url): return "can't read \(url.lastPathComponent)"
            case .tooShort(let source, let encoded):
                return "encoded \(encoded) of \(source) frames"
            case .noUsableTracks: return "no readable audio tracks"
            }
        }
    }

    private struct StereoTrack {
        let url: URL
        let offsetMs: Int
    }

    /// Stream two independently recorded tracks into a stereo AAC file. This
    /// never holds more than a few seconds in memory, even for a long meeting.
    private static func encodeStereo(
        mic: StereoTrack?,
        system: StereoTrack?,
        to destination: URL
    ) throws -> String {
        let fm = FileManager.default

        func source(_ track: StereoTrack?) throws -> StereoSource? {
            guard let track else { return nil }
            guard fm.fileExists(atPath: track.url.path) else { return nil }
            guard let file = try? AVAudioFile(forReading: track.url), file.length > 0 else {
                throw CompressionError.unreadable(track.url)
            }
            return StereoSource(file: file, offsetMs: track.offsetMs)
        }

        let micSource = try source(mic)
        let systemSource = try source(system)
        let sources = [micSource, systemSource].compactMap { $0 }
        guard !sources.isEmpty else { throw CompressionError.noUsableTracks }

        let rate = sources.map(\.rate).max()!
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ), let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false
        ) else { throw CompressionError.noUsableTracks }

        let micReader = micSource.flatMap { StereoReader($0, to: mono) }
        let systemReader = systemSource.flatMap { StereoReader($0, to: mono) }
        let totalFrames = sources.map { source in
            AVAudioFramePosition((Double(source.file.length) * rate / source.rate).rounded(.up))
                + AVAudioFramePosition(Double(source.offsetMs) * rate / 1000)
        }.max()!
        let blockFrames = AVAudioFrameCount(rate)
        try? fm.removeItem(at: destination)

        func writeArchive() throws {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: blockFrames)
            else { throw CompressionError.noUsableTracks }

            var position: AVAudioFramePosition = 0
            while position < totalFrames {
                let count = AVAudioFrameCount(min(
                    AVAudioFramePosition(blockFrames), totalFrames - position))
                buffer.frameLength = count
                buffer.floatChannelData![0].update(repeating: 0, count: Int(count))
                buffer.floatChannelData![1].update(repeating: 0, count: Int(count))
                micReader?.fill(buffer.floatChannelData![0], frames: count, at: position)
                systemReader?.fill(buffer.floatChannelData![1], frames: count, at: position)
                try output.write(from: buffer)
                position += AVAudioFramePosition(count)
            }
        }
        try writeArchive()

        let encoded = try AVAudioFile(forReading: destination)
        guard encoded.processingFormat.channelCount == 2,
              Double(encoded.length) >= Double(totalFrames) * 0.99
        else {
            throw CompressionError.tooShort(source: totalFrames, encoded: encoded.length)
        }

        let before = sources.reduce(Int64(0)) { $0 + size(of: $1.file.url) }
        return "\(mb(before)) → \(mb(size(of: destination)))"
    }

    private struct StereoSource {
        let file: AVAudioFile
        let offsetMs: Int
        var rate: Double { file.processingFormat.sampleRate }
    }

    /// AVAudioConverter invokes its input block synchronously; each reader is
    /// confined to the one compression call despite the block's Sendable type.
    private final class StereoReader: @unchecked Sendable {
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let staging: AVAudioPCMBuffer
        private let format: AVAudioFormat
        private let start: AVAudioFramePosition
        private var spent = false

        init?(_ source: StereoSource, to format: AVAudioFormat) {
            let input = source.file.processingFormat
            guard let converter = AVAudioConverter(from: input, to: format),
                  let staging = AVAudioPCMBuffer(
                    pcmFormat: input,
                    frameCapacity: AVAudioFrameCount(input.sampleRate))
            else { return nil }
            file = source.file
            self.converter = converter
            self.staging = staging
            self.format = format
            start = AVAudioFramePosition(Double(source.offsetMs) * format.sampleRate / 1000)
        }

        func fill(
            _ destination: UnsafeMutablePointer<Float>,
            frames: AVAudioFrameCount,
            at position: AVAudioFramePosition
        ) {
            guard !spent else { return }
            let lead = max(0, start - position)
            guard lead < AVAudioFramePosition(frames) else { return }
            let wanted = frames - AVAudioFrameCount(lead)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted)
            else { return }

            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, status in
                staging.frameLength = 0
                guard file.framePosition < file.length,
                      (try? file.read(into: staging)) != nil,
                      staging.frameLength > 0
                else {
                    status.pointee = .endOfStream
                    return nil
                }
                status.pointee = .haveData
                return staging
            }
            if status == .endOfStream || status == .error { spent = true }
            guard output.frameLength > 0, let samples = output.floatChannelData?[0] else { return }
            destination.advanced(by: Int(lead)).update(
                from: samples,
                count: Int(output.frameLength))
        }
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
