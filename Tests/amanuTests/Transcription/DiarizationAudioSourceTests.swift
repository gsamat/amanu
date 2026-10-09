import AVFoundation
import Foundation
import Testing
@testable import amanu

struct DiarizationAudioSourceTests {
    @Test("A stereo AAC archive channel is decoded to 16 kHz PCM without another AAC encode")
    func encodedArchiveChannel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("audio.m4a")
        try TestAudio.write(
            to: archive, seconds: 1, sampleRate: 48_000, channels: 2,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]) { channel, frame in
                channel == 0 ? 0 : 0.5 * Float(sin(2 * .pi * 440 * Double(frame) / 48_000))
            }

        let prepared = try DiarizationAudioSource.prepare(
            input: archive, channel: 1, trackID: "them", clock: .sessionAligned,
            destination: directory.appendingPathComponent("diarization-source-them.caf"))
        let output = try AVAudioFile(forReading: prepared.url)
        #expect(output.fileFormat.settings[AVFormatIDKey] as? Int == Int(kAudioFormatLinearPCM))
        #expect(output.processingFormat.sampleRate == 16_000)
        #expect(output.processingFormat.channelCount == 1)
        #expect(abs(prepared.sampleCount - 16_000) < 1_024)
        #expect(try samples(in: prepared.url, range: 4_000..<4_100).contains { abs($0) > 0.1 })
    }

    @Test("A recorded offset is applied once while an archived channel is already aligned")
    func recordedAndArchiveClocks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = directory.appendingPathComponent("raw.caf")
        try TestAudio.write(to: raw, sampleRate: 16_000, samples: [[Float](repeating: 0.5, count: 16_000)])
        let recorded = try DiarizationAudioSource.prepare(
            input: raw, channel: nil, trackID: "them", clock: .recorded(offsetMs: 250),
            destination: directory.appendingPathComponent("diarization-source-them.caf"))
        #expect(recorded.sampleRate == 16_000)
        #expect(recorded.sampleCount == 20_000)
        #expect(try samples(in: recorded.url, range: 0..<4_000).allSatisfy { $0 == 0 })
        #expect(try samples(in: recorded.url, range: 4_000..<4_100).allSatisfy { abs($0 - 0.5) < 0.001 })

        let archive = directory.appendingPathComponent("archive.caf")
        try TestAudio.write(to: archive, sampleRate: 16_000, samples: [
            [Float](repeating: 0.25, count: 16_000),
            [Float](repeating: 0.75, count: 16_000),
        ])
        let aligned = try DiarizationAudioSource.prepare(
            input: archive, channel: 1, trackID: "them", clock: .sessionAligned,
            destination: directory.appendingPathComponent("aligned.caf"))
        #expect(aligned.sampleCount == 16_000)
        #expect(try samples(in: aligned.url, range: 0..<100).allSatisfy { abs($0 - 0.75) < 0.001 })
        #expect(aligned.fingerprint != recorded.fingerprint)
    }

    @Test("Source fingerprint follows decoded samples and a failed replacement keeps the last good source")
    func fingerprintAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.caf")
        let destination = directory.appendingPathComponent("diarization-source-source.caf")
        try TestAudio.write(to: input, sampleRate: 16_000, samples: [[Float](repeating: 0.1, count: 16_000)])
        let first = try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: "source", clock: .sessionAligned,
            destination: destination)
        let repeatSource = try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: "source", clock: .sessionAligned,
            destination: destination)
        #expect(first.fingerprint == repeatSource.fingerprint)

        try TestAudio.write(to: input, sampleRate: 16_000, samples: [[Float](repeating: 0.2, count: 16_000)])
        let changed = try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: "source", clock: .sessionAligned,
            destination: destination)
        #expect(changed.fingerprint != first.fingerprint)

        try Data("not audio".utf8).write(to: input)
        #expect(throws: AudioChannelExtractor.ExtractionError.self) {
            try DiarizationAudioSource.prepare(
                input: input, channel: nil, trackID: "source", clock: .sessionAligned,
                destination: destination)
        }
        #expect(try samples(in: destination, range: 0..<100).allSatisfy { abs($0 - 0.2) < 0.001 })
    }

    private func samples(in url: URL, range: Range<Int>) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)))
        file.framePosition = AVAudioFramePosition(range.lowerBound)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
        let data = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
