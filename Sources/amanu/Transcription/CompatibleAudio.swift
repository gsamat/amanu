import AVFoundation
import CryptoKit
import Foundation

/// A single clock for all three HTTP profiles. Resample and mix every input
/// channel once, then cut on exact PCM frames; never cut by compressed bytes.
enum CompatibleAudio {
    static let rate = 16_000.0
    static let version = "mono16k-pcm16-v1"
    // Core Audio's AAC encoder does not accept 64 kbps at 16 kHz mono.
    static let aacBitRate = 48_000

    struct Piece: Sendable {
        let url: URL
        let firstFrame: Int64
        let frames: Int64
        var offset: TimeInterval { Double(firstFrame) / rate }
        var duration: TimeInterval { Double(frames) / rate }
    }

    struct Prepared: Sendable {
        let pieces: [Piece]
        let fingerprint: String
    }

    static func prepare(
        _ source: URL, in directory: URL, aac: Bool,
        chunkDuration: TimeInterval, maximumUploadBytes: Int
    ) async throws -> Prepared {
        // maximumUploadBytes is OpenRouter's encoded AAC limit. Neither the
        // native MLX endpoint nor this DeepInfra model documents a WAV byte
        // limit; imposing OpenRouter's 24 MB on them would change the accepted
        // 40-minute strategy. Their explicit 413 is an unsuccessful request.
        let worker = Task.detached(priority: .utility) {
            let normalized = directory.appendingPathComponent("normalized.wav")
            try normalize(source, to: normalized)
            let fingerprint = try digest(normalized)
            let file = try AVAudioFile(forReading: normalized)
            let limit = Int64((chunkDuration * rate).rounded(.down))
            guard limit > 0 else {
                throw CompatibleTranscriptionEngine.Failure.configuration("chunk duration must be positive")
            }
            var pieces: [Piece] = []
            var offset: Int64 = 0
            while offset < file.length {
                try Task.checkCancellation()
                var count = min(limit, file.length - offset)
                let url = directory.appendingPathComponent(
                    "part-\(pieces.count + 1).\(aac ? "m4a" : "wav")")
                while true {
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: url)
                    try write(file, firstFrame: offset, frames: count, to: url, aac: aac)
                    // URL resource values cache the previous file's size.
                    // This path is rewritten when shrinking: always stat it.
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                    guard aac, size >= maximumUploadBytes else { break }
                    // AAC's actual size is what the API limits. Leave room for
                    // encoder overhead; the discarded tail is the next piece.
                    let shorter = Int64(Double(count) * Double(maximumUploadBytes) / Double(size) * 0.9)
                    guard shorter > 0, shorter < count else {
                        throw CompatibleTranscriptionEngine.Failure.uploadTooLarge
                    }
                    count = shorter
                }
                pieces.append(Piece(url: url, firstFrame: offset, frames: count))
                offset += count
            }
            return Prepared(pieces: pieces, fingerprint: fingerprint)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func normalize(_ source: URL, to destination: URL) throws {
        let reader = try AudioTrackReader(url: source, rate: rate)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: Int64 = 0
        while let buffer = try reader.next(16_000) {
            try Task.checkCancellation()
            try output.write(from: buffer)
            frames += Int64(buffer.frameLength)
        }
        guard frames > 0 else { throw CompatibleTranscriptionEngine.Failure.invalidAudio }
        // Converter priming may change a handful of frames, not a recording's
        // length. A failed conversion must not turn the remainder into silence.
        guard abs(frames - reader.length) <= 1_600 else {
            throw CompatibleTranscriptionEngine.Failure.invalidAudio
        }
    }

    private static func write(
        _ source: AVAudioFile, firstFrame: Int64, frames: Int64, to url: URL, aac: Bool
    ) throws {
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: aacBitRate]
            : AudioFormats.pcmSettings(sampleRate: rate, channels: 1)
        let output = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 16_000)
        else { throw CompatibleTranscriptionEngine.Failure.invalidAudio }
        source.framePosition = firstFrame
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            try source.read(into: buffer, frameCount: AVAudioFrameCount(min(16_000, remaining)))
            guard buffer.frameLength > 0 else { throw CompatibleTranscriptionEngine.Failure.invalidAudio }
            try output.write(from: buffer)
            remaining -= Int64(buffer.frameLength)
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
