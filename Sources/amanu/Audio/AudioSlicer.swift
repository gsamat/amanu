import AVFoundation
import Foundation

/// Cuts one audio file into consecutive pieces small enough to upload, each
/// cut in a pause rather than through a word.
///
/// This exists for OpenAI, which refuses anything over 25 MB or, for the
/// diarizing model, over 1400 seconds per request. Nobody should have to know
/// that, so the engine slices, transcribes each piece, and shifts
/// the timings back onto the session's clock; the transcript comes out looking
/// like one pass.
///
/// The pieces are written frame by frame through `AVAudioFile` rather than by
/// `AVAssetExportSession`, for the reason `AudioMixer` explains at length: the
/// export path makes macOS ask for Photos and Music access, which is an
/// absurd thing for a meeting recorder to do.
enum AudioSlicer {
    struct Slice: Sendable {
        let url: URL
        /// Where this piece starts in the source, in seconds. What gets added
        /// back to every timestamp the engine returns for it.
        let offset: TimeInterval
    }

    enum SliceError: Error, CustomStringConvertible {
        case unreadable(URL, Error?)
        case unwritable(URL, Error)

        var description: String {
            switch self {
            case .unreadable(let url, let error):
                return "can't read \(url.lastPathComponent)"
                    + (error.map { ": \($0)" } ?? "")
            case .unwritable(let url, let error):
                return "can't write \(url.lastPathComponent): \(error)"
            }
        }
    }

    /// Split `source` into pieces of at most `seconds` each, written into
    /// `directory`, each cut at the quietest moment in the last `window`
    /// seconds before the limit. A source already short enough is not copied
    /// — the single slice points at the original file, so the common case
    /// touches no disk.
    static func slice(
        _ source: URL,
        every seconds: TimeInterval,
        into directory: URL,
        window: TimeInterval = 30
    ) async throws -> [Slice] {
        try await Task.detached(priority: .utility) {
            try sliceNow(source, every: seconds, into: directory, window: window)
        }.value
    }

    /// The bitrate every piece is written at, whatever the source's.
    static let encodedBitRate = 64_000

    /// How long each piece may be to stay under `limit` bytes and
    /// `maxDuration` seconds. Returns nil when the whole thing already fits.
    ///
    /// Bytes are counted at the source's bitrate or the pieces' 64k, whichever
    /// is higher: the pieces are re-encoded, and sized at a quieter mix's
    /// lower rate alone they come out over 25 MB — which the API answers with
    /// "Audio file might be corrupted or unsupported". The margin covers the
    /// variation a constant-bitrate estimate leaves: a piece that comes back
    /// slightly over the limit costs the whole transcription, and a piece 15%
    /// shorter than it had to be costs nothing at all.
    static func sliceLength(
        bytes: Int64,
        duration: TimeInterval,
        limit: Int64,
        maxDuration: TimeInterval = .infinity,
        margin: Double = 0.85
    ) -> TimeInterval? {
        guard bytes > limit || duration > maxDuration, duration > 0, bytes > 0 else { return nil }
        let bytesPerSecond = max(Double(bytes) / duration, Double(encodedBitRate) / 8)
        let seconds = min(maxDuration, Double(limit) * margin / bytesPerSecond)
        // Never below a minute: a limit that small means the numbers are wrong,
        // and hundreds of tiny uploads is not a better failure than one refusal.
        return max(60, seconds)
    }

    /// Where to cut a recording of `levels` (RMS per `bucket` seconds) so no
    /// piece is longer than `seconds`: at the quietest moment of the last
    /// `window` before each limit, the latest of equals. Pure, so where the
    /// cuts fall is testable without audio.
    static func cuts(
        levels: [Float], bucket: TimeInterval, every seconds: TimeInterval, window: TimeInterval
    ) -> [TimeInterval] {
        let duration = Double(levels.count) * bucket
        let half = Int((0.25 / bucket).rounded())
        var cuts: [TimeInterval] = []
        var start: TimeInterval = 0
        while duration - start > seconds {
            let last = Int(((start + seconds) / bucket).rounded(.down))
            let first = max(Int(((start + seconds - window) / bucket).rounded(.up)),
                            Int((start / bucket).rounded(.down)) + 1)
            var best = last
            var quietest = Float.greatestFiniteMagnitude
            for index in stride(from: last, through: first, by: -1) {
                let around = levels[max(0, index - half)..<min(levels.count, index + half + 1)]
                let level = around.reduce(0, +) / Float(around.count)
                if level < quietest { (quietest, best) = (level, index) }
            }
            start = Double(best) * bucket
            cuts.append(start)
        }
        return cuts
    }

    // MARK: -

    private static func sliceNow(
        _ source: URL,
        every seconds: TimeInterval,
        into directory: URL,
        window: TimeInterval
    ) throws -> [Slice] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw SliceError.unreadable(source, error)
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard file.length > 0, rate > 0 else { throw SliceError.unreadable(source, nil) }

        let duration = Double(file.length) / rate
        guard duration > seconds else { return [Slice(url: source, offset: 0)] }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        // A second at a time, like the mixer: small enough that a long meeting
        // never holds more than a few hundred kilobytes of audio in memory.
        let blockFrames = AVAudioFrameCount(rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw SliceError.unreadable(source, nil)
        }
        // A first pass for loudness, because where a cut goes depends on audio
        // the piece before it does not contain. The bucket is a whole number of
        // frames, and its length in seconds is that number's: at 11,025 Hz a
        // tenth of a second is 1102.5 frames, and over three hours the half
        // frame would move a cut seconds away from the pause it chose.
        let size = max(1, Int(rate / 10))
        let bucket = Double(size) / rate
        let ends = cuts(
            levels: try levels(of: file, buffer: buffer, size: size, source: source),
            bucket: bucket, every: seconds, window: window
        ).map { AVAudioFramePosition(($0 * rate).rounded()) } + [file.length]
        file.framePosition = 0

        var slices: [Slice] = []
        var index = 0
        while index < ends.count, file.framePosition < file.length {
            let start = file.framePosition
            let url = directory.appendingPathComponent(
                "slice-\(String(format: "%03d", index)).m4a")
            try? FileManager.default.removeItem(at: url)

            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: format.channelCount,
                // The same 64k mono the mix itself is written at:
                // re-encoding at a lower rate would shrink the upload
                // and cost accuracy on exactly the audio that needs it.
                AVEncoderBitRateKey: encodedBitRate,
            ]
            let output: AVAudioFile
            do {
                output = try AVAudioFile(
                    forWriting: url, settings: settings,
                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            } catch {
                // The encoder refuses 64k below about 24 kHz — an imported
                // 16 kHz recording, say — and its own default there is lower.
                settings[AVEncoderBitRateKey] = nil
                try? FileManager.default.removeItem(at: url)
                do {
                    output = try AVAudioFile(
                        forWriting: url, settings: settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                } catch {
                    throw SliceError.unwritable(url, error)
                }
            }

            let sliceFrames = ends[index] - start
            var written: AVAudioFramePosition = 0
            while written < sliceFrames, file.framePosition < file.length {
                let wanted = AVAudioFrameCount(min(
                    AVAudioFramePosition(blockFrames), sliceFrames - written))
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer, frameCount: wanted)
                } catch {
                    throw SliceError.unreadable(source, error)
                }
                guard buffer.frameLength > 0 else { break }
                do {
                    try output.write(from: buffer)
                } catch {
                    throw SliceError.unwritable(url, error)
                }
                written += AVAudioFramePosition(buffer.frameLength)
            }

            guard written > 0 else {
                try? FileManager.default.removeItem(at: url)
                break
            }
            slices.append(Slice(url: url, offset: Double(start) / rate))
            index += 1
        }
        return slices
    }

    /// RMS of every `size` frames of `file`, all channels together.
    private static func levels(
        of file: AVAudioFile, buffer: AVAudioPCMBuffer, size: Int, source: URL
    ) throws -> [Float] {
        let channels = Int(file.processingFormat.channelCount)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: buffer.frameCapacity)
            } catch {
                throw SliceError.unreadable(source, error)
            }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                for channel in 0..<channels { sum += data[channel][frame] * data[channel][frame] }
                count += 1
                if count == size {
                    levels.append((sum / Float(size * channels)).squareRoot())
                    (sum, count) = (0, 0)
                }
            }
        }
        if count > 0 { levels.append((sum / Float(count * channels)).squareRoot()) }
        return levels
    }
}
