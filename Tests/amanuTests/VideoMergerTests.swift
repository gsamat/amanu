import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import amanu

/// The merged file, built from real bytes: a written-and-finalized video,
/// two PCM tracks with an offset between them, and assertions on what comes
/// out the other side. No Screen Recording grant — every input here is
/// manufactured.
/// Serialized, as every suite that builds a real encoder is: the hardware
/// H.264 encoder is one resource, and several of these at once leaves the code
/// waiting on VideoToolbox rather than testing it.
@Suite(.serialized) struct VideoMergerTests {
    /// The fixture's video did not seal. Thrown rather than recorded: a merge
    /// against a file that is not there fails later and somewhere else, and
    /// that is the failure somebody spends an hour on.
    struct FixtureFailed: Error, CustomStringConvertible {
        let why: String
        var description: String { "the fixture video did not seal: \(why)" }
    }
    /// One second of quiet PCM in a CAF — the format the recorders write.
    private func audioFile(seconds: Double, at url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        else { return }
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: 48_000, channels: 1),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func videoFile(seconds: Double, at url: URL) throws {
        let writer = try VideoFileWriter(
            outputURL: url, width: 64, height: 64, frameRate: 30, bitrate: 300_000
        )
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            let timestamp = CMTime(value: CMTimeValue(frame), timescale: 30)
            writer.startSessionIfNeeded(at: timestamp)
            writer.append(try sampleBuffer(at: timestamp))
            // The test loop is a far faster producer than any meeting: let
            // each frame land before offering the next.
            var waited = 0
            while writer.framesWritten < frame + 1, waited < 2_000 {
                usleep(1_000)
                waited += 1
            }
        }
        // A loaded runner can cost frames; the merge needs a sealed file with
        // the picture in it, not an exact count.
        let outcome = writer.finalize()
        guard case .finished(let written, _) = outcome, written > 0 else {
            throw FixtureFailed(why: "\(outcome) — \(writer.failureNote ?? "no note")")
        }
    }

    /// One 64×64 BGRA frame — the same shape VideoRecorderTests builds.
    private func sampleBuffer(at pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = pixelBuffer!
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    @Test func videoAndAudioLandOnOneClock() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("video.mp4")
        try videoFile(seconds: 3.0, at: video)
        // Offsets on the shared clock: the mic starts 0.5 s in, the system at
        // the beginning — so the mix runs 2.5 s.
        let mic = dir.appendingPathComponent("mic.caf")
        try audioFile(seconds: 2.0, at: mic)
        let system = dir.appendingPathComponent("system.caf")
        try audioFile(seconds: 2.5, at: system)

        let output = dir.appendingPathComponent("meeting.mp4")
        try await VideoMerger.merge(
            video: video, videoOffsetMs: 500,
            mic: TrackCompressor.StereoTrack(url: mic, offsetMs: 500),
            system: TrackCompressor.StereoTrack(url: system, offsetMs: 0),
            to: output
        )

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
        let duration = try await asset.load(.duration)
        // The video starts 0.5 s in and runs 3 s past that.
        #expect(abs(duration.seconds - 3.5) < 0.3)

        // The sources were never the merge's to touch.
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: mic.path))
        #expect(FileManager.default.fileExists(atPath: system.path))
        // And the mix temp went with the merge.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.tmp.m4a").path))
    }

    /// A merge with no offset is the ordinary case: the video starts at zero
    /// beside its audio, and the file is playable end to end.
    @Test func aZeroOffsetMergeIsTheWholeMeeting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-merge-zero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("video.mp4")
        try videoFile(seconds: 1.0, at: video)
        let mic = dir.appendingPathComponent("mic.caf")
        try audioFile(seconds: 1.0, at: mic)

        let output = dir.appendingPathComponent("meeting.mp4")
        try await VideoMerger.merge(
            video: video, videoOffsetMs: 0,
            mic: TrackCompressor.StereoTrack(url: mic, offsetMs: 0),
            system: nil,
            to: output
        )

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 1.0) < 0.2)
    }

    /// The menu-driven case the whole feature exists for: audio runs from
    /// the start, video joins part-way through. The mix keeps the meeting's
    /// clock, the picture lands where it belongs on it, and the lead-in is
    /// sound-only.
    @Test func videoStartingLateKeepsTheAudioClock() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-merge-late-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("video.mp4")
        try videoFile(seconds: 8.0, at: video)
        let mic = dir.appendingPathComponent("mic.caf")
        try audioFile(seconds: 20.0, at: mic)
        let system = dir.appendingPathComponent("system.caf")
        try audioFile(seconds: 20.0, at: system)

        let output = dir.appendingPathComponent("meeting.mp4")
        try await VideoMerger.merge(
            video: video, videoOffsetMs: 10_000,
            mic: TrackCompressor.StereoTrack(url: mic, offsetMs: 0),
            system: TrackCompressor.StereoTrack(url: system, offsetMs: 0),
            to: output
        )

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        // Audio runs the whole meeting; the video ends at 18s and the file
        // carries on to the audio's end.
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 20.0) < 0.5)
    }

    /// One missing track degrades to the other rather than losing the file —
    /// the same rule the stereo archive follows.
    @Test func aMissingSystemTrackStillMerges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-merge-half-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("video.mp4")
        try videoFile(seconds: 1.0, at: video)
        let mic = dir.appendingPathComponent("mic.caf")
        try audioFile(seconds: 2.0, at: mic)

        let output = dir.appendingPathComponent("meeting.mp4")
        try await VideoMerger.merge(
            video: video, videoOffsetMs: 0,
            mic: TrackCompressor.StereoTrack(url: mic, offsetMs: 0),
            system: nil,
            to: output
        )
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
