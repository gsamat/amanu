import AVFoundation
import Foundation
import Testing

@testable import amanu

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
        gain: Float,
        rate: Double = 48000.0
    ) throws {
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
                .appendingPathComponent("amanu-attr-\(UUID().uuidString)", isDirectory: true)
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

    /// Catches treating a stereo archive as two identical downmixed files,
    /// which credits every utterance to the same side after PCM is removed.
    @Test("Speaker attribution reads archive channels independently")
    func archivedChannelsStayIndependent() throws {
        let f = try Fixture()
        try JSONSerialization.data(withJSONObject: [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 500],
        ]).write(to: f.dir.appendingPathComponent("meta.json"), options: .atomic)
        TrackCompressor.compress(sessionDir: f.dir)

        let archive = f.dir.appendingPathComponent("audio.m4a")
        let segments = [Self.seg(0.1, 1.9, "A"), Self.seg(3.1, 4.9, "B")]
        #expect(SpeakerAttribution.resolve(
            segments: segments,
            mic: archive,
            micOffset: 0,
            system: archive,
            systemOffset: 0
        ) == ["me", "them"])
    }

    @Test("A stretch silent on both tracks inherits its label's usual side")
    func silentStretchInheritsSide() throws {
        let f = try Fixture()
        #expect(
            f.resolve([Self.seg(0.1, 1.9, "A"), Self.seg(8.2, 9.4, "A"), Self.seg(3.1, 4.9, "B")])
                == ["me", "me", "them"])
    }

    /// The failure this floor exists for, measured on a real session: the far
    /// end spoke on the system track, the mic carried nothing but room noise,
    /// and per-track normalization made that noise look exactly like speech —
    /// every utterance came back credited to "me".
    ///
    /// The mechanism is worth stating, because it is not obvious: normalizing
    /// against a track's own p90 means a *uniform* track (noise) always reads
    /// at ~1.0, while a track carrying real speech reads below its own p90
    /// wherever the speaker pauses. So noise beats speech whenever the
    /// utterance window contains a breath.
    @Test("A track holding only room noise loses to the one holding speech")
    func noiseOnlyTrackLosesToSpeech() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-noise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let noisy = dir.appendingPathComponent("mic.caf")
        let speech = dir.appendingPathComponent("system.caf")
        // An open mic in a quiet room: continuous, featureless, about −60 dBFS.
        try Self.writeTrack(to: noisy, seconds: 10, bursts: [(0, 10)], gain: 0.001)
        // The far end talking, with a pause where someone drew breath.
        try Self.writeTrack(to: speech, seconds: 10, bursts: [(3, 4), (4.5, 5)], gain: 0.7)

        #expect(
            SpeakerAttribution.resolve(
                segments: [Self.seg(3.0, 5.0, "A")],
                mic: noisy, micOffset: 0, system: speech, systemOffset: 0) == ["them"])
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

    /// Duration alone would pass on a mix that quietly dropped one track, which
    /// is the failure that costs a meeting half its transcript. So look at the
    /// samples: each speaker's window has to be loud and the pauses quiet.
    @Test("Both tracks are audible in the mix, each in its own window")
    func mixCarriesBothTracks() async throws {
        let f = try Fixture()
        let mixed = f.dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [
                AudioMixer.Track(url: f.mic, offset: 0),
                AudioMixer.Track(url: f.system, offset: 0.5),
            ],
            to: mixed)

        // mic speaks 0–2s, system 3.0–5.0s on the shared clock, both silent
        // in between; gains stay ~9x apart, so the check is against each
        // track's own level rather than a shared one.
        #expect(try Self.peak(of: mixed, from: 0.5, to: 1.5) > 0.04, "mic track missing")
        #expect(try Self.peak(of: mixed, from: 3.5, to: 4.5) > 0.3, "system track missing")
        #expect(try Self.peak(of: mixed, from: 2.0, to: 2.8) < 0.01, "silence between is not silent")
    }

    /// Two devices rarely agree on a sample rate — a 44.1k interface against a
    /// 48k tap is the ordinary case, and the old composition-based mix hid the
    /// resampling. Doing it by hand means a wrong ratio would stretch one
    /// track's timeline and put every far-side word in the wrong place.
    @Test("Tracks at different sample rates keep their timing")
    func mixResamplesWithoutDrift() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-rates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fast = dir.appendingPathComponent("mic.caf")
        let slow = dir.appendingPathComponent("system.caf")
        try Self.writeTrack(to: fast, seconds: 10, bursts: [(0, 2)], gain: 0.5)
        try Self.writeTrack(to: slow, seconds: 10, bursts: [(7, 9)], gain: 0.5, rate: 44100)

        let mixed = dir.appendingPathComponent("mixed.m4a")
        try await AudioMixer.mix(
            [AudioMixer.Track(url: fast, offset: 0), AudioMixer.Track(url: slow, offset: 0)],
            to: mixed)

        // A 44.1/48 ratio applied the wrong way round would drag the 7–9s
        // burst to 6.4–8.3 or push it to 7.6–9.8; a whole second of margin
        // either side of the check catches both.
        #expect(try Self.peak(of: mixed, from: 0.5, to: 1.5) > 0.2, "48k track missing")
        #expect(try Self.peak(of: mixed, from: 7.5, to: 8.5) > 0.2, "44.1k track missing or drifted")
        #expect(try Self.peak(of: mixed, from: 4.0, to: 6.0) < 0.01, "silence between is not silent")
    }

    /// Loudest sample between two times, read straight off the file.
    private static func peak(of url: URL, from start: Double, to end: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let first = AVAudioFramePosition(start * format.sampleRate)
        let frames = AVAudioFrameCount((end - start) * format.sampleRate)
        guard first < file.length, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: frames)
        else { return 0 }
        file.framePosition = first
        try file.read(into: buffer, frameCount: frames)
        return AudioLevel.peak(of: buffer) ?? 0
    }
}
