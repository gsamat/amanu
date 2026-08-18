import AVFoundation
import Foundation

/// Turns a finished session's PCM tracks into AAC and deletes the originals.
///
/// Recording writes uncompressed PCM because that is the only format that
/// survives a hard kill (see AudioFormats), at about a gigabyte an hour across
/// both tracks. That's a fine price for the duration of a meeting and a silly
/// one for an archive, so once the transcript exists — the thing the audio was
/// for — the tracks are compressed and the PCM goes.
///
/// Order matters and is deliberate: transcript first, then compression. If
/// anything here fails, the session still has its transcript and its original
/// audio; the worst case is a folder that stayed large.
enum TrackCompressor {
    /// Compress every PCM track named in meta.json, rewrite meta.json to point
    /// at the compressed files, and delete what's been replaced.
    static func compress(sessionDir dir: URL) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }
        guard Config.compressTracks() else { return }

        let metaURL = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metaURL),
            var meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var files = meta["files"] as? [String: String]
        else {
            log("compression skipped — can't read meta.json")
            return
        }

        var replaced = false
        for (track, name) in files where name.hasSuffix(".caf") {
            let source = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = source.deletingPathExtension().appendingPathExtension("m4a")

            do {
                let saved = try encode(source, to: destination)
                files[track] = destination.lastPathComponent
                replaced = true
                log("compressed \(name) → \(destination.lastPathComponent) (\(saved))")
            } catch {
                // Leave this track as PCM and keep the others' results: a
                // failed encode must never cost the audio it was compressing.
                try? FileManager.default.removeItem(at: destination)
                log("compression of \(name) failed, keeping the original: \(error)")
            }
        }
        guard replaced else { return }

        meta["files"] = files
        meta["compressed"] = true
        guard let updated = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else {
            log("compression done but meta.json could not be rewritten — keeping the PCM")
            return
        }
        // The PCM is deleted only after meta.json points somewhere else, so an
        // interruption at any point leaves a session that still resolves to
        // files that exist.
        do {
            try updated.write(to: metaURL, options: .atomic)
        } catch {
            log("couldn't rewrite meta.json (\(error)) — keeping the PCM")
            return
        }

        guard !Config.keepUncompressed() else { return }
        for name in files.values {
            let pcm = dir.appendingPathComponent(name)
                .deletingPathExtension().appendingPathExtension("caf")
            try? FileManager.default.removeItem(at: pcm)
        }
        // Derived from the tracks and regenerated on demand; keeping it costs
        // more than the tracks themselves.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("mixed.m4a"))
    }

    // MARK: -

    enum CompressionError: Error, CustomStringConvertible {
        case unreadable(URL)
        case tooShort(source: Int64, encoded: Int64)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't read \(url.lastPathComponent)"
            case .tooShort(let source, let encoded):
                return "encoded \(encoded) of \(source) frames"
            }
        }
    }

    /// Encode one file to AAC, streaming, and verify the result covers the
    /// source before the caller is allowed to delete anything. Returns a short
    /// human-readable size comparison. Internal rather than private so the
    /// verification step can be tested on its own.
    static func encode(_ source: URL, to destination: URL) throws -> String {
        guard let input = try? AVAudioFile(forReading: source), input.length > 0 else {
            throw CompressionError.unreadable(source)
        }
        let format = input.processingFormat
        try? FileManager.default.removeItem(at: destination)

        // Scoped so the writer is released — and the file therefore closed and
        // its container finalized — before anything tries to read it back. An
        // m4a whose writer is still alive has no index yet and opens as an
        // invalid file.
        func writeEncoded() throws {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    // Speech, not music: 64k mono and 96k stereo are
                    // transparent enough that no transcriber can tell, at about
                    // a twentieth of the size.
                    AVEncoderBitRateKey: format.channelCount > 1 ? 96_000 : 64_000,
                ],
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)
            ) else { throw CompressionError.unreadable(source) }

            // Bounded by framePosition rather than by a zero-length read:
            // reading past the end of an AVAudioFile throws rather than
            // returning nothing, so "read until it comes back empty" ends every
            // encode in a spurious failure.
            while input.framePosition < input.length {
                buffer.frameLength = 0
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        try writeEncoded()

        // Verify before anything is deleted. AAC pads with priming frames, so
        // the encoded file is a little longer than the source, never shorter;
        // a truncated encode is the failure that would cost the meeting.
        let encoded = try AVAudioFile(forReading: destination).length
        guard Double(encoded) >= Double(input.length) * 0.99 else {
            throw CompressionError.tooShort(source: input.length, encoded: encoded)
        }

        let before = size(of: source), after = size(of: destination)
        return "\(mb(before)) → \(mb(after))"
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
