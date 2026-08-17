import AVFoundation
import Foundation
import Testing

@testable import quill

/// Attribution and mixing are pure functions over audio files, so they're
/// testable without a meeting: synthesize two tracks with known speech
/// windows, then assert who each utterance gets credited to.
struct SpeakerAttributionTests {
    /// An AAC-in-CAF track shaped like MicRecorder/SystemAudioRecorder write:
    /// `bursts` are (start, end) seconds of tone, everything else silence.
    private static func writeTrack(
        to url: URL,
        seconds: Double,
        bursts: [(Double, Double)],
        gain: Float
    ) throws {
        let rate = 48000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        let chunk = AVAudioFrameCount(4800)
        var frame = 0
        let total = Int(seconds * rate)
        while frame < total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
            let n = min(Int(chunk), total - frame)
            buffer.frameLength = AVAudioFrameCount(n)
            let data = buffer.floatChannelData![0]
            for i in 0..<n {
                let t = Double(frame + i) / rate
                let live = bursts.contains { t >= $0.0 && t < $0.1 }
                data[i] = live ? gain * Float(sin(2 * .pi * 220 * t)) : 0
            }
            try file.write(from: buffer)
            frame += n
        }
    }

    /// mic speaks 0–2s and 6–8s; system speaks 2.5–4.5s in its own timeline
    /// and starts 0.5s late, so on the shared clock it lands at 3.0–5.0s.
    /// Gains differ ~9x on purpose — two real tracks never match levels.
    private final class Fixture {
        let dir: URL
        let mic: URL
        let system: URL

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-attr-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            mic = dir.appendingPathComponent("mic.caf")
            system = dir.appendingPathComponent("system.caf")
            try SpeakerAttributionTests.writeTrack(
                to: mic, seconds: 10, bursts: [(0, 2), (6, 8)], gain: 0.08)
            try SpeakerAttributionTests.writeTrack(
                to: system, seconds: 10, bursts: [(2.5, 4.5)], gain: 0.7)
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        func resolve(_ segments: [TranscriptSegment]) -> [String]? {
            SpeakerAttribution.resolve(
                segments: segments, mic: mic, micOffset: 0, system: system, systemOffset: 0.5)
        }
    }

    private static func seg(
        _ start: Double, _ end: Double, _ speaker: String?
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "…", speaker: speaker)
    }

    @Test("Two diarization labels are split by which track was loud")
    func twoLabelsSplitByTrack() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 4.9, "B"), Self.seg(6.1, 7.9, "A")])
                == ["me", "them", "me"])
    }

    /// The case that per-label attribution got wrong: a diarizer that merges
    /// two similar voices into one label still has to come out split, because
    /// the source tracks disagree even when the model doesn't.
    @Test("One merged label is still split by track")
    func oneLabelStillSplitByTrack() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 4.9, "A"), Self.seg(6.1, 7.9, "A")])
                == ["me", "them", "me"])
    }

    @Test("Segments with no diarization label still get a side")
    func unlabelledSegmentsGetASide() throws {
        let f = try Fixture()
        #expect(f.resolve([Self.seg(0.1, 1.9, nil), Self.seg(3.1, 4.9, nil)]) == ["me", "them"])
    }

    /// Several people sharing the far-side channel is the thing only
    /// diarization can resolve, so labels survive as suffixes there — but the
    /// lone mic speaker stays plain "me" rather than "me A".
    @Test("Multiple far-side speakers keep their labels as suffixes")
    func farSideSpeakersKeepLabels() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 3.9, "B"), Self.seg(4.0, 4.9, "C")])
                == ["me", "them A", "them B"])
    }

    @Test("A one-sided recording is a legitimate all-me answer")
    func oneSidedRecording() throws {
        let f = try Fixture()
        #expect(f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(6.1, 7.9, "A")]) == ["me", "me"])
    }

    @Test("A stretch silent on both tracks inherits its label's usual side")
    func silentStretchInheritsSide() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(8.2, 9.4, "A"), Self.seg(3.1, 4.9, "B")])
                == ["me", "me", "them"])
    }

    @Test("A missing track refuses to attribute rather than guessing")
    func missingTrackRefuses() throws {
        let f = try Fixture()
        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(0.1, 1.9, "A")],
                mic: f.dir.appendingPathComponent("nope.caf"), micOffset: 0,
                system: f.system, systemOffset: 0.5) == nil)
    }

    @Test("A silent track refuses to attribute rather than guessing")
    func silentTrackRefuses() throws {
        let f = try Fixture()
        let silent = f.dir.appendingPathComponent("silent.caf")
        try Self.writeTrack(to: silent, seconds: 10, bursts: [], gain: 0)
        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(0.1, 1.9, "A")],
                mic: silent, micOffset: 0, system: f.system, systemOffset: 0.5) == nil)
    }

    @Test("No segments refuses to attribute")
    func noSegmentsRefuses() throws {
        let f = try Fixture()
        #expect(f.resolve([]) == nil)
    }

    @Test("The mix lays each track in at its own start offset")
    func mixHonoursOffsets() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [
                AudioMixer.Track(url: f.mic, offset: 0),
                AudioMixer.Track(url: f.system, offset: 0.5),
            ],
            to: mixed)
        let duration = try await AVURLAsset(url: mixed).load(.duration).seconds
        // 10s of track laid in at +0.5s.
        #expect(duration > 10.3 && duration < 11.0, "expected ~10.5s, got \(duration)")
    }

    /// A leftover mix from a failed run used to wedge every retry, since
    /// export refuses to overwrite.
    @Test("Mixing over an existing file replaces it")
    func mixOverwrites() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix([AudioMixer.Track(url: f.mic, offset: 0)], to: mixed)
        try await AudioMixer.mix([AudioMixer.Track(url: f.system, offset: 0)], to: mixed)
        #expect(FileManager.default.fileExists(atPath: mixed.path))
    }
}
