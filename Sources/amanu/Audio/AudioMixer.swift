import AVFoundation
import Foundation

/// Mixes a session's tracks down to one file on the shared clock — each track
/// laid in at its own start offset, so the mix has the same timeline the
/// two-track transcript would.
///
/// This exists for diarizing engines: they need a single stream with everybody
/// on it, and there's no way to diarize across two files. The output is m4a
/// (AAC in MP4) rather than CAF because it goes to an API — m4a is what
/// everything accepts. Unlike the source tracks, the mix isn't crash-safe, but
/// it doesn't need to be: it's derived, and regenerating it costs seconds.
///
/// The samples are summed by hand rather than by `AVAssetExportSession`, and
/// that is not a stylistic preference. The export path drags in AVFoundation's
/// whole media-library machinery, and macOS answers that by asking the user for
/// Photos, Media & Apple Music and Documents-folder access — three scary
/// dialogs, mid-meeting, from a program that has no business near any of them.
/// (Confirmed by the clock: "mixing tracks" at 12:28:31, three prompts at
/// 12:28:45–50.) Reading frames through `AVAudioFile`, adding them, and writing
/// them back asks for nothing.
enum AudioMixer {
    struct Track: Sendable {
        let url: URL
        let offset: TimeInterval
    }

    enum MixError: Error, CustomStringConvertible {
        case noUsableTracks
        case outputUnavailable(Error)

        var description: String {
            switch self {
            case .noUsableTracks: return "no readable audio tracks to mix"
            case .outputUnavailable(let error): return "couldn't open the mix for writing: \(error)"
            }
        }
    }

    /// Write `tracks` mixed down into `output`, replacing whatever was there.
    /// A track that's missing, empty, or unreadable is skipped — one dead
    /// track shouldn't cost the other one its transcript.
    static func mix(_ tracks: [Track], to output: URL) async throws {
        // Off the cooperative pool: this is a few seconds of solid arithmetic
        // and encoding per hour of meeting, and the pool has a recording to run.
        try await Task.detached(priority: .utility) { try mixNow(tracks, to: output) }.value
    }

    // MARK: -

    /// One second of output at a time. Big enough that the per-block bookkeeping
    /// disappears next to the arithmetic, small enough that an hour-long meeting
    /// never holds more than a few hundred kilobytes of audio in memory — the
    /// mistake the predecessor made was keeping whole meetings resident.
    private static func mixNow(_ tracks: [Track], to output: URL) throws {
        let sources = tracks.compactMap { Source($0) }
        guard !sources.isEmpty else { throw MixError.noUsableTracks }

        // Mono, at the fastest rate any source runs at: the mix is speech
        // headed for a transcriber, so a second channel would only carry the
        // same words twice, and downsampling is a decision better left to
        // whoever consumes it.
        let rate = sources.map(\.rate).max()!
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw MixError.noUsableTracks }
        let blockFrames = AVAudioFrameCount(rate)

        // Two blocks in rotation plus a silent one. Two, because the last block
        // of the mix is the only one allowed to be short and there is no way to
        // know a block is the last until the next one comes back empty — so one
        // block is always held back, written in full once something follows it
        // and trimmed to its real length if nothing does. Getting this wrong
        // rounds the mix up to the next whole second and slides nothing else,
        // which is exactly the kind of bug a duration assertion catches and an
        // ear doesn't.
        guard
            let first = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
            let second = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)
        else { throw MixError.noUsableTracks }
        silence.frameLength = blockFrames
        silence.floatChannelData![0].update(repeating: 0, count: Int(blockFrames))

        let readers = sources.compactMap { Reader($0, to: format) }
        guard !readers.isEmpty else { throw MixError.noUsableTracks }

        // AVAudioFile won't overwrite, and a leftover from a failed run would
        // otherwise wedge every retry.
        try? FileManager.default.removeItem(at: output)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: output,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 1,
                    // Same reasoning as TrackCompressor: 64k mono is
                    // transparent for speech at a twentieth of the size.
                    AVEncoderBitRateKey: 64_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
        } catch {
            throw MixError.outputUnavailable(error)
        }

        var work = first
        var pending: AVAudioPCMBuffer?
        var pendingFrames = 0
        /// Blocks that came out entirely silent since `pending`. Held rather
        /// than written, because a run of them at the very end is just the tail
        /// of the shorter track and belongs nowhere; anywhere else they're a
        /// real gap on the shared clock and get written out in full.
        var gap = 0
        var position: AVAudioFramePosition = 0

        while readers.contains(where: { !$0.spent }) {
            let mixed = work.floatChannelData![0]
            mixed.update(repeating: 0, count: Int(blockFrames))
            var filled = 0

            for reader in readers where !reader.spent {
                // Where inside this block the track's own timeline begins.
                // Zero once it's running: it just keeps flowing.
                let lead = max(0, reader.start - position)
                guard lead < AVAudioFramePosition(blockFrames) else { continue }
                guard let chunk = reader.next(blockFrames - AVAudioFrameCount(lead)) else {
                    continue
                }

                let samples = chunk.floatChannelData![0]
                let base = Int(lead)
                for i in 0..<Int(chunk.frameLength) { mixed[base + i] += samples[i] }
                filled = max(filled, base + Int(chunk.frameLength))
            }
            position += AVAudioFramePosition(blockFrames)

            guard filled > 0 else {
                gap += 1
                continue
            }
            // Two people talking at once can sum past full scale. Clamping
            // costs a moment of flattened peak; letting the encoder deal with
            // it costs a burst of noise over the loudest words.
            for i in 0..<filled { mixed[i] = min(1, max(-1, mixed[i])) }

            var free = work === first ? second : first
            if let held = pending {
                held.frameLength = blockFrames
                try file.write(from: held)
                free = held
            }
            for _ in 0..<gap { try file.write(from: silence) }
            gap = 0

            pending = work
            pendingFrames = filled
            work = free
        }

        if let held = pending, pendingFrames > 0 {
            held.frameLength = AVAudioFrameCount(pendingFrames)
            try file.write(from: held)
        }
    }

    /// A track that opened and has something in it. Split out from `Reader` so
    /// the output sample rate can be chosen from every source before any
    /// converter is built.
    private struct Source {
        let file: AVAudioFile
        let start: TimeInterval
        var rate: Double { file.processingFormat.sampleRate }

        init?(_ track: Track) {
            guard
                FileManager.default.fileExists(atPath: track.url.path),
                let file = try? AVAudioFile(forReading: track.url),
                file.length > 0
            else { return nil }
            self.file = file
            self.start = track.offset
        }
    }

    /// One source, resampled to the mix's format and handed out in pieces.
    ///
    /// `@unchecked Sendable` because `AVAudioConverter`'s input block is typed
    /// `@Sendable` while being documented to run synchronously inside
    /// `convert(to:error:withInputFrom:)` — one reader never crosses a thread,
    /// it just gets called back on the one it's already on.
    private final class Reader: @unchecked Sendable {
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let staging: AVAudioPCMBuffer
        private let format: AVAudioFormat

        /// First frame of the mix this track contributes to.
        let start: AVAudioFramePosition
        /// Nothing left, or nothing readable left. Either way, stop asking.
        private(set) var spent = false

        init?(_ source: Source, to format: AVAudioFormat) {
            let input = source.file.processingFormat
            guard
                let converter = AVAudioConverter(from: input, to: format),
                let staging = AVAudioPCMBuffer(
                    pcmFormat: input, frameCapacity: AVAudioFrameCount(input.sampleRate))
            else { return nil }
            self.file = source.file
            self.converter = converter
            self.staging = staging
            self.format = format
            self.start = AVAudioFramePosition((source.start * format.sampleRate).rounded())
        }

        /// Up to `frames` of mix-format audio, or nil once the track is spent.
        func next(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
            guard !spent, frames > 0,
                let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { return nil }

            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [self] _, status in
                staging.frameLength = 0
                // Bounded by framePosition, not by a short read: reading past
                // the end throws instead of returning nothing, so "read until
                // it comes back empty" ends every mix in a spurious failure.
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

            if status == .endOfStream || status == .error {
                spent = true
                if status == .error, let error {
                    // Truncated tail, unreadable packets — drop the rest of this
                    // track rather than the whole mix, same as the per-track
                    // path does.
                    FileHandle.standardError.write(Data(
                        "warning: \(file.url.lastPathComponent) ends early in the mix: \(error)\n"
                            .utf8))
                }
            }
            return out.frameLength > 0 ? out : nil
        }
    }
}
