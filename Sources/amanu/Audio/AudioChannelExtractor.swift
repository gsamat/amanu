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
}
