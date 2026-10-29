import AVFoundation
import Foundation

/// A few seconds of a recording as a 16 kHz mono WAV: what OpenAI takes as a
/// sample of a known speaker's voice. 16 kHz because the sample travels
/// base64-encoded with every piece of the meeting, and the mix's own 48 kHz
/// would triple that for nothing a voice needs.
enum AudioClip {
    struct ClipError: Error, CustomStringConvertible {
        let description: String
    }

    static func wav(from source: URL, start: TimeInterval, length: TimeInterval) throws -> Data {
        let file = try AVAudioFile(forReading: source)
        let input = file.processingFormat
        let first = AVAudioFramePosition(max(0, start) * input.sampleRate)
        let frames = AVAudioFrameCount(max(0, min(
            Double(file.length - first), length * input.sampleRate)))
        guard frames > 0, let samples = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)
        else { throw ClipError(description: "the clip lies outside \(source.lastPathComponent)") }
        file.framePosition = first
        try file.read(into: samples, frameCount: frames)

        // AVAudioFile writes at its own rate without converting, so the
        // conversion is done here.
        guard let output = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output),
              let converted = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / input.sampleRate) + 4096)
        else { throw ClipError(description: "can't convert a clip to 16 kHz") }
        let feed = Feed(samples)
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, state in feed.next(state) }
        guard status != .error, converted.frameLength > 0 else {
            throw ClipError(description: "can't convert a clip: \(failure.map { "\($0)" } ?? "no audio")")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(converted, to: url)
        return try Data(contentsOf: url)
    }

    /// A function of its own so the file is closed, and complete, before it
    /// is read back.
    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: buffer.format.settings,
            commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }

    /// Hands the converter its one buffer, then says that was all.
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                state.pointee = .endOfStream
                return nil
            }
            self.buffer = nil
            state.pointee = .haveData
            return buffer
        }
    }
}
