import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import amanu

/// Building `meeting.mp4` again for a merge that never finished.
///
/// The interesting state is the one a crash leaves behind: `video.mp4` sealed
/// and in the folder, `meeting.tmp.*` littering it, no `merged` in the session
/// state — and the audio cleanup deferred, waiting for a merge that is no
/// longer coming. The re-merge is what that state is waiting for.
@Suite(.serialized) struct VideoRemergeTests {
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
        let outcome = writer.finalize()
        guard case .finished(let written, _) = outcome, written > 0 else {
            throw FixtureFailed(why: "\(outcome) — \(writer.failureNote ?? "no note")")
        }
    }

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

    /// A session as a crash mid-merge leaves it: the finished `video.mp4`, the
    /// two audio tracks the deferred cleanup spared, meta.json saying a video
    /// was made — and no `meeting.mp4`. `withVideo: false` is the recording
    /// before that, whose meta.json has no video in it at all.
    private func unfinishedSession(withVideo: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-remerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try videoFile(seconds: 2.0, at: dir.appendingPathComponent("video.mp4"))
        try audioFile(seconds: 2.0, at: dir.appendingPathComponent("mic.caf"))
        try audioFile(seconds: 2.0, at: dir.appendingPathComponent("system.caf"))

        var meta: [String: Any] = [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 0],
            "duration_seconds": 2,
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ]
        if withVideo {
            meta["video"] = "video.mp4"
            meta["video_capture"] = "window"
            meta["video_start_offset_ms"] = 400
        }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    @Test func remergeBuildsTheMergedFileAndSaysSo() async throws {
        let dir = try unfinishedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Litter from the merge that never finished: the re-merge is what
        // clears it.
        try Data("partial".utf8).write(to: dir.appendingPathComponent("meeting.tmp.mp4"))

        let output = try await VideoMerger.remerge(sessionDir: dir)

        #expect(output.lastPathComponent == "meeting.mp4")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        // The sources were never the merge's to touch, and the litter from the
        // interrupted attempt went with it.
        for name in ["video.mp4", "mic.caf", "system.caf"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.tmp.mp4").path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.tmp.m4a").path))

        // The session state says the merge happened, which is what retires the
        // deferred audio cleanup and the table's re-merge button.
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("meta.json"))
        ) as? [String: Any]
        #expect(meta?["merged"] as? String == "meeting.mp4")
    }

    /// Two merges in one folder delete each other's half-written work — the
    /// names in the middle (`meeting.tmp.m4a`, `meeting.tmp.mp4`) are the same
    /// every time — and the first reports it as a Core Audio error about a file
    /// that was there a moment ago. The claim is what keeps the second one out.
    @Test func aHeldClaimKeepsASecondMergeOut() async throws {
        let dir = try unfinishedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SessionClaim.acquireMerge(dir)
        defer { SessionClaim.releaseMerge(dir) }

        await #expect(throws: SessionClaim.Busy.self) {
            _ = try await VideoMerger.remerge(sessionDir: dir)
        }

        // The one that backed off leaves the folder exactly as it found it: the
        // winner's claim is still there, nothing was written, and the session is
        // not marked failed — it is being merged, not broken.
        #expect(FileManager.default.fileExists(
            atPath: SessionClaim.url(dir, SessionClaim.mergeFile).path))
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.mp4").path))
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("meta.json"))
        ) as? [String: Any]
        #expect(meta?["merge_failed"] == nil)
    }

    /// And the claim is given back, or one merge would keep the next one out of
    /// the folder for ever.
    @Test func aFinishedMergeGivesTheFolderBack() async throws {
        let dir = try unfinishedSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await VideoMerger.remerge(sessionDir: dir)

        #expect(!SessionClaim.isMergeHeld(dir))
        #expect(!FileManager.default.fileExists(
            atPath: SessionClaim.url(dir, SessionClaim.mergeFile).path))
    }

    @Test func aSessionWithNoRecordedVideoCannotBeRemerged() async throws {
        let dir = try unfinishedSession(withVideo: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: (any Error).self) {
            _ = try await VideoMerger.remerge(sessionDir: dir)
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.mp4").path))
    }

    /// The state sessions from before the deferred cleanup could reach: the
    /// merge failed, the audio was settled anyway, and the re-merge has nothing
    /// to read. The point is the *sentence* — a missing track has to be named
    /// as missing, not surface as a Core Audio error nobody can act on.
    @Test func aMissingTrackIsNamedRatherThanOpened() async throws {
        let dir = try unfinishedSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("system.caf"))

        do {
            _ = try await VideoMerger.remerge(sessionDir: dir)
            Issue.record("a re-merge with no system track should not have run")
        } catch let error as VideoMerger.MergeError {
            guard case .remergeImpossible(_, let why) = error else {
                Issue.record("expected remergeImpossible, got \(error)")
                return
            }
            #expect(why.contains("system.caf"))
        } catch {
            Issue.record("expected a MergeError, got \(error)")
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meeting.mp4").path))
    }
}

/// The recordings table's re-merge button, decided as pure data.
@MainActor
@Suite struct RemergeVideoButtonTests {
    @Test("The button belongs to a video whose merged copy is missing")
    func offeredForRawVideoOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-remerge-button-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeSession(
            name: String, videoKey: Bool, videoFile: Bool, mergedFile: Bool,
            audio: Bool = true
        ) throws -> URL {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var meta: [String: Any] = [
                "files": ["mic": "mic.caf", "system": "system.caf"],
                "duration_seconds": 2,
            ]
            if videoKey { meta["video"] = "video.mp4" }
            if videoFile {
                try Data("picture".utf8).write(to: dir.appendingPathComponent("video.mp4"))
            }
            if mergedFile {
                try Data("picture".utf8).write(to: dir.appendingPathComponent("meeting.mp4"))
            }
            // The material the re-merge reads. It is there in every session the
            // table offers the button for, so its absence is its own case below.
            if audio {
                for track in ["mic.caf", "system.caf"] {
                    try Data("pcm".utf8).write(to: dir.appendingPathComponent(track))
                }
            }
            try JSONSerialization.data(withJSONObject: meta)
                .write(to: dir.appendingPathComponent("meta.json"))
            return dir
        }

        let raw = try writeSession(
            name: "a-raw", videoKey: true, videoFile: true, mergedFile: false)
        let merged = try writeSession(
            name: "b-merged", videoKey: true, videoFile: false, mergedFile: true)
        let noVideo = try writeSession(
            name: "c-none", videoKey: false, videoFile: false, mergedFile: false)
        let noAudio = try writeSession(
            name: "d-gone", videoKey: true, videoFile: true, mergedFile: false, audio: false)

        let rawItem = try #require(SessionInventory.item(for: raw))
        #expect(RecordingsWindow.inlineRemergeVideoTitle(for: rawItem)
            == localised("Re-merge video", "Собрать видео заново"))

        // The merged copy is there, so there is nothing to build again.
        let mergedItem = try #require(SessionInventory.item(for: merged))
        #expect(RecordingsWindow.inlineRemergeVideoTitle(for: mergedItem) == nil)

        // And a recording with no video never grows a merge button.
        let noVideoItem = try #require(SessionInventory.item(for: noVideo))
        #expect(RecordingsWindow.inlineRemergeVideoTitle(for: noVideoItem) == nil)

        // A session whose audio was settled away has nothing to merge from.
        let noAudioItem = try #require(SessionInventory.item(for: noAudio))
        #expect(RecordingsWindow.inlineRemergeVideoTitle(for: noAudioItem) == nil)
    }
}
