import AVFoundation
import Foundation
import Testing

@testable import amanu

/// Raw capture taps the device at its native format and converts to mono.
/// An audio interface such as an RME Babyface presents its inputs as one device
/// with a discrete channel layout, and the microphone sits on input 1.
struct MicDownmixTests {
    /// `AVAudioConverter` has no rule for folding a discrete layout into mono,
    /// so it maps no input channel to the output and writes digital zeros — a
    /// mic track of silence with a perfectly normal duration.
    @Test("A mic on input 1 of a multichannel interface reaches the mono track",
          arguments: [2, 14] as [UInt32])
    func firstInputOfDiscreteLayoutIsKept(channels: UInt32) throws {
        let layout = try #require(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            interleaved: false, channelLayout: layout)
        let mono = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        let first = try #require(buffer.floatChannelData?[0])
        for i in 0..<480 { first[i] = 0.5 }

        let converter = try #require(MicRecorder.downmixConverter(from: input, to: mono))
        let out = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 544))
        try converter.convert(to: out, from: buffer)

        #expect(out.frameLength == 480)
        #expect(try #require(AudioLevel.peak(of: out)) > 0.4)
    }
}
