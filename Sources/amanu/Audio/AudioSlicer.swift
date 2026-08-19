import AVFoundation
import Foundation

/// Cuts one audio file into consecutive pieces small enough to upload.
///
/// This exists for OpenAI, which refuses anything over 25 MB per request — a
/// limit an hour-long meeting passes at the mix's own bitrate. Nobody should
/// have to know that, so the engine slices, transcribes each piece, and shifts
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
    /// `directory`. A source already short enough is not copied — the single
    /// slice points at the original file, so the common case touches no disk.
    static func slice(
        _ source: URL,
        every seconds: TimeInterval,
        into directory: URL
    ) async throws -> [Slice] {
        try await Task.detached(priority: .utility) {
            try sliceNow(source, every: seconds, into: directory)
        }.value
    }

    /// How long each piece may be for a file of this size to fit under
    /// `limit`, at the source's own average bitrate. Returns nil when the
    /// whole thing already fits.
    ///
    /// The average is honest enough for speech at a constant bitrate, and the
    /// margin below covers the variation that is left: a piece that comes back
    /// slightly over the limit costs the whole transcription, and a piece 15%
    /// shorter than it had to be costs nothing at all.
    static func sliceLength(
        bytes: Int64,
        duration: TimeInterval,
        limit: Int64,
        margin: Double = 0.85
    ) -> TimeInterval? {
        guard bytes > limit, duration > 0, bytes > 0 else { return nil }
        let allowed = Double(limit) * margin
        let seconds = duration * allowed / Double(bytes)
        // Never below a minute: a limit that small means the numbers are wrong,
        // and hundreds of tiny uploads is not a better failure than one refusal.
        return max(60, seconds)
    }

    // MARK: -

    private static func sliceNow(
        _ source: URL,
        every seconds: TimeInterval,
        into directory: URL
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

        let sliceFrames = AVAudioFramePosition(seconds * rate)
        // A second at a time, like the mixer: small enough that a long meeting
        // never holds more than a few hundred kilobytes of audio in memory.
        let blockFrames = AVAudioFrameCount(rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw SliceError.unreadable(source, nil)
        }

        var slices: [Slice] = []
        var index = 0
        while file.framePosition < file.length {
            let start = file.framePosition
            let url = directory.appendingPathComponent(
                "slice-\(String(format: "%03d", index)).m4a")
            try? FileManager.default.removeItem(at: url)

            let output: AVAudioFile
            do {
                output = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: rate,
                        AVNumberOfChannelsKey: format.channelCount,
                        // The same 64k mono the mix itself is written at:
                        // re-encoding at a lower rate would shrink the upload
                        // and cost accuracy on exactly the audio that needs it.
                        AVEncoderBitRateKey: 64_000,
                    ],
                    commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved)
            } catch {
                throw SliceError.unwritable(url, error)
            }

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
}
