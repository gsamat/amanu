import AVFoundation
import CryptoKit
import Foundation

/// A durable PCM track on the session clock. The source remains readable until
/// the session's retention stage explicitly removes it.
enum DiarizationAudioSource {
    enum Clock: Codable, Hashable, Sendable {
        case recorded(offsetMs: Int)
        case sessionAligned
    }

    struct Prepared: Codable, Sendable {
        let url: URL
        let trackID: String
        let sampleRate: Int
        let sampleCount: Int64
        let clock: Clock
        let fingerprint: String

        var duration: TimeInterval { Double(sampleCount) / Double(sampleRate) }
    }

    enum SourceError: Error {
        case invalidPath
        case invalidTrack
        case invalidOffset
        case invalidPCM
    }

    static func prepare(
        input: URL, channel: Int?, trackID: String, clock: Clock, destination: URL
    ) throws -> Prepared {
        guard input.isFileURL, destination.isFileURL,
              input.standardizedFileURL != destination.standardizedFileURL
        else { throw SourceError.invalidPath }
        guard !trackID.isEmpty,
              trackID.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                  || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 })
        else { throw SourceError.invalidTrack }
        let leadingSamples: Int64
        switch clock {
        case .sessionAligned:
            leadingSamples = 0
        case .recorded(let offsetMs):
            guard offsetMs >= 0 else { throw SourceError.invalidOffset }
            let product = Int64(offsetMs).multipliedReportingOverflow(by: 16)
            guard !product.overflow else { throw SourceError.invalidOffset }
            leadingSamples = product.partialValue
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp.caf")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let count = try AudioChannelExtractor.extractPCM(
            channel: channel, from: input, to: temporary,
            leadingSamples: leadingSamples)
        let fingerprint = try hashPCM(
            temporary, sampleCount: count, trackID: trackID, clock: clock)
        try Task<Never, Never>.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return Prepared(
            url: destination, trackID: trackID, sampleRate: 16_000,
            sampleCount: count, clock: clock, fingerprint: fingerprint)
    }

    static func verify(_ source: Prepared) throws {
        guard source.url.isFileURL, source.sampleRate == 16_000,
              source.sampleCount > 0,
              try hashPCM(
                source.url, sampleCount: source.sampleCount,
                trackID: source.trackID, clock: source.clock) == source.fingerprint
        else { throw SourceError.invalidPCM }
    }

    /// Only literal digital zeros establish that a diarizer's no-speech result
    /// cannot have discarded a quiet nonzero utterance.
    static func isDigitallySilent(_ source: Prepared) throws -> Bool {
        let file = try AVAudioFile(forReading: source.url)
        guard file.length == source.sampleCount,
              file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              file.processingFormat.commonFormat == .pcmFormatFloat32,
              let block = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { throw SourceError.invalidPCM }
        while file.framePosition < file.length {
            try Task<Never, Never>.checkCancellation()
            try file.read(into: block, frameCount: AVAudioFrameCount(
                min(16_384, file.length - file.framePosition)))
            guard block.frameLength > 0, let samples = block.floatChannelData?[0]
            else { throw SourceError.invalidPCM }
            for index in 0..<Int(block.frameLength) where samples[index] != 0 {
                return false
            }
        }
        return true
    }

    private static func hashPCM(
        _ url: URL, sampleCount: Int64, trackID: String, clock: Clock
    ) throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard file.length == sampleCount,
              file.processingFormat.channelCount == 1,
              file.processingFormat.sampleRate == 16_000,
              file.processingFormat.commonFormat == .pcmFormatFloat32,
              let block = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { throw SourceError.invalidPCM }
        var hash = SHA256()
        var read: Int64 = 0
        while read < sampleCount {
            try Task<Never, Never>.checkCancellation()
            try file.read(into: block, frameCount: AVAudioFrameCount(min(16_384, sampleCount - read)))
            guard block.frameLength > 0, let samples = block.floatChannelData?[0]
            else { throw SourceError.invalidPCM }
            hash.update(data: Data(bytes: samples, count: Int(block.frameLength) * MemoryLayout<Float>.size))
            read += Int64(block.frameLength)
        }
        let clockID: String
        switch clock {
        case .sessionAligned: clockID = "session-aligned"
        case .recorded(let offsetMs): clockID = "recorded:\(offsetMs)ms"
        }
        hash.update(data: Data("pcm-f32le-v1|16000|\(sampleCount)|\(trackID)|\(clockID)".utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
