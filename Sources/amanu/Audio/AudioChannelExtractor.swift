import AVFoundation
import Foundation

/// Materializes one channel of a stereo archive as a temporary mono AAC file.
/// Per-track transcription engines need this after the original PCM tracks
/// have been replaced by `audio.m4a`.
enum AudioChannelExtractor {
    enum ExtractionError: Error, CustomStringConvertible {
        case unreadable(URL)
        case missingChannel(Int)
        case unsupportedFormat
        case tooShort(source: Int64, extracted: Int64)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't read \(url.lastPathComponent)"
            case .missingChannel(let channel): return "audio has no channel \(channel)"
            case .unsupportedFormat: return "audio can't be read as non-interleaved float samples"
            case .tooShort(let source, let extracted):
                return "extracted \(extracted) of \(source) frames"
            }
        }
    }

    static func extract(channel: Int, from source: URL, to destination: URL) throws {
        guard let input = try? AVAudioFile(forReading: source), input.length > 0 else {
            throw ExtractionError.unreadable(source)
        }
        let inputFormat = input.processingFormat
        guard channel >= 0, channel < Int(inputFormat.channelCount) else {
            throw ExtractionError.missingChannel(channel)
        }
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false)
        else { throw ExtractionError.unsupportedFormat }

        try? FileManager.default.removeItem(at: destination)
        func writeExtracted() throws {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: inputFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
            let block = AVAudioFrameCount(inputFormat.sampleRate)
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: block),
                  let monoBuffer = AVAudioPCMBuffer(
                    pcmFormat: monoFormat, frameCapacity: block)
            else { throw ExtractionError.unsupportedFormat }

            while input.framePosition < input.length {
                sourceBuffer.frameLength = 0
                try input.read(into: sourceBuffer)
                guard sourceBuffer.frameLength > 0,
                      let sourceSamples = sourceBuffer.floatChannelData?[channel],
                      let monoSamples = monoBuffer.floatChannelData?[0]
                else { break }
                monoBuffer.frameLength = sourceBuffer.frameLength
                monoSamples.update(from: sourceSamples, count: Int(sourceBuffer.frameLength))
                try output.write(from: monoBuffer)
            }
        }
        try writeExtracted()

        let extracted = try AVAudioFile(forReading: destination).length
        guard Double(extracted) >= Double(input.length) * 0.99 else {
            throw ExtractionError.tooShort(source: input.length, extracted: extracted)
        }
    }

    /// Decode a track or one archive channel directly to lossless mono PCM.
    /// The caller owns the destination and publishes it only after validation.
    static func extractPCM(
        channel: Int?, from source: URL, to destination: URL,
        leadingSamples: Int64 = 0
    ) throws -> Int64 {
        guard leadingSamples >= 0,
              let input = try? AVAudioFile(forReading: source), input.length > 0
        else { throw ExtractionError.unreadable(source) }
        let inputFormat = input.processingFormat
        if let channel {
            guard channel >= 0, channel < Int(inputFormat.channelCount) else {
                throw ExtractionError.missingChannel(channel)
            }
        }
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: mono),
              let staging = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4096)
        else { throw ExtractionError.unsupportedFormat }
        if let channel {
            converter.channelMap = [NSNumber(value: channel)]
        } else {
            converter.downmix = true
        }

        let written = try { () throws -> Int64 in
            let file = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: true,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)

            var written: Int64 = 0
            var padding = leadingSamples
            while padding > 0 {
                try Task<Never, Never>.checkCancellation()
                let count = Int(min(padding, Int64(output.frameCapacity)))
                output.frameLength = AVAudioFrameCount(count)
                output.floatChannelData![0].update(repeating: 0, count: count)
                try file.write(from: output)
                written += Int64(count)
                padding -= Int64(count)
            }

            var idle = 0
            while true {
                try Task<Never, Never>.checkCancellation()
                output.frameLength = 0
                var readError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { requested, state in
                    guard input.framePosition < input.length else {
                        state.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try input.read(into: staging, frameCount: max(1, min(requested, staging.frameCapacity)))
                        guard staging.frameLength > 0 else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        state.pointee = .haveData
                        return staging
                    } catch {
                        readError = error
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                if status == .error { throw ExtractionError.unsupportedFormat }
                if output.frameLength > 0 {
                    guard let samples = output.floatChannelData?[0],
                          (0..<Int(output.frameLength)).allSatisfy({ samples[$0].isFinite })
                    else { throw ExtractionError.unsupportedFormat }
                    try file.write(from: output)
                    written += Int64(output.frameLength)
                    idle = 0
                } else {
                    idle += 1
                }
                if status == .endOfStream { break }
                guard idle < 3 else { throw ExtractionError.tooShort(source: input.length, extracted: written) }
            }
            return written
        }()
        guard written > leadingSamples,
              try AVAudioFile(forReading: destination).length == written
        else { throw ExtractionError.tooShort(source: input.length, extracted: written) }
        return written
    }
}
