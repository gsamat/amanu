import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import amanu

/// The video writer, fed with buffers we make ourselves — a real stream
/// would need a Screen Recording grant and a meeting; the writer only needs
/// pixels, and the pixels are where the file is won or lost.
///
/// Serialized, as the other suites that build a real encoder are: the hardware
/// H.264 encoder is one resource, and six of these at once leaves the code
/// waiting on VideoToolbox rather than testing it.
@Suite(.serialized) struct VideoFileWriterTests {
    /// One 64×64 BGRA frame in a CMSampleBuffer, the same shape the stream
    /// hands over: image buffer, format description, timing.
    private func sampleBuffer(at pts: CMTime, width: Int = 64, height: Int = 64)
        -> CMSampleBuffer
    {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        let buffer = pixelBuffer!
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format
        )
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

    /// Wait, bounded, for the encoder to have taken at least one frame: a
    /// loaded runner can leave it unready for seconds, and a file with nothing
    /// in it is deleted by design rather than sealed.
    private static func waitForAFrame(_ writer: VideoFileWriter) -> Bool {
        var waited = 0
        while writer.framesWritten == 0, waited < 5_000 {
            usleep(1_000)
            waited += 1
        }
        return writer.framesWritten > 0
    }

    @Test func writtenFramesMakeAPlayableFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-video-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try VideoFileWriter(
            outputURL: url, width: 64, height: 64, frameRate: 30, bitrate: 300_000
        )
        for frame in 0..<90 {
            let timestamp = CMTime(value: CMTimeValue(frame), timescale: 30)
            writer.startSessionIfNeeded(at: timestamp)
            writer.append(sampleBuffer(at: timestamp))
            // The test loop is a far faster producer than any meeting: wait
            // for this frame to land before offering the next, since the
            // encoder's readiness comes back asynchronously.
            var waited = 0
            while writer.framesWritten < frame + 1, waited < 2_000 {
                usleep(1_000)
                waited += 1
            }
        }

        // The encoder is asynchronous and a loaded machine can cost a frame
        // even with the loop waiting for each one, so what is asserted here is
        // the file: it exists, it has picture in it, one track, the size it was
        // built for, and about the three seconds that went in. The counts are
        // in the failure message for the day it is the counts that matter.
        let outcome = writer.finalize()
        guard case .finished(let written, _) = outcome, written > 0 else {
            Issue.record("nothing was written: \(outcome) — \(writer.failureNote ?? "no note")")
            return
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 2.0 && duration.seconds < 3.2)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 64))
    }

    /// A frame in another size is dropped, not fed to the encoder: one H.264
    /// session has one size for its whole life, and what the encoder does
    /// with a mismatched frame is fail the recording — -16122, measured on
    /// 16 September 2026, when the window-follow re-pick let the captured
    /// window change size and the whole video was discarded at stop.
    @Test func aFrameOfAnotherSizeIsDroppedAndTheFileStillSeals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-video-size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = try VideoFileWriter(
            outputURL: dir.appendingPathComponent("video.mp4"),
            width: 64, height: 64, frameRate: 30, bitrate: 300_000)
        for frame in 0..<4 {
            let timestamp = CMTime(value: CMTimeValue(frame), timescale: 30)
            writer.startSessionIfNeeded(at: timestamp)
            writer.append(sampleBuffer(at: timestamp))
        }
        // How many of those the encoder took is its business — this test is
        // about the frame that arrives in a size it cannot use — but at least
        // one has to be in the file, and `quiesce` only drains the queue.
        #expect(writer.quiesce())
        guard Self.waitForAFrame(writer) else {
            Issue.record("no frame was encoded, so there is no file to seal")
            return
        }
        let accepted = writer.framesWritten
        let droppedBefore = writer.framesDropped

        // The size a re-picked window could deliver.
        writer.append(sampleBuffer(at: CMTime(value: 10, timescale: 30), width: 32, height: 32))
        #expect(writer.quiesce())

        #expect(writer.framesWritten == accepted, "the odd-sized frame added nothing")
        #expect(writer.framesDropped == droppedBefore + 1)
        // And the recording survives it: the file seals, where feeding the
        // encoder that frame used to end the whole video in failure.
        if case .finished = writer.finalize() {
        } else {
            Issue.record("the file did not seal")
        }
    }

    /// A stream that delivered nothing — a permission silently missing, a
    /// display asleep — must leave nothing behind that reads as a recording.
    @Test func aWriterWithNoFramesLeavesNoFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-video-empty-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try VideoFileWriter(
            outputURL: url, width: 64, height: 64, frameRate: 30, bitrate: 300_000
        )
        #expect(writer.finalize() == .empty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Pause drops frames at the recorder, but the writer itself must also
    /// survive appends after it has sealed the file — a late buffer from a
    /// stream that missed the memo is dropped, not a crash.
    @Test func appendingAfterFinalizeIsHarmless() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-video-late-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try VideoFileWriter(
            outputURL: url, width: 64, height: 64, frameRate: 30, bitrate: 300_000
        )
        writer.startSessionIfNeeded(at: .zero)
        writer.append(sampleBuffer(at: .zero))
        _ = writer.quiesce()
        _ = writer.finalize()
        writer.append(sampleBuffer(at: CMTime(value: 1, timescale: 30)))
        // Give the late frame its turn before asking what happened to it:
        // without this the append is still queued and the answer is one
        // whatever the writer does with it.
        #expect(writer.quiesce())
        #expect(writer.framesWritten == 1)
    }
}

/// The scaling rule: down to the ceiling, never up, never odd.
struct VideoOutputSizeTests {
    @Test func aLargeSourceScalesToTheCeiling() {
        #expect(
            VideoRecorder.outputSize(sourcePixels: CGSize(width: 2560, height: 1440), ceiling: 1080)
                == (width: 1920, height: 1080)
        )
    }

    /// A small window is recorded as it is — upscaling buys nothing but
    /// bitrate.
    @Test func aSmallSourceIsNeverUpscaled() {
        #expect(
            VideoRecorder.outputSize(sourcePixels: CGSize(width: 1280, height: 720), ceiling: 1080)
                == (width: 1280, height: 720)
        )
    }

    /// H.264 refuses odd dimensions; rounding goes down so the file's frame
    /// size never lies about what arrived.
    @Test func oddDimensionsRoundDownToEven() {
        let size = VideoRecorder.outputSize(
            sourcePixels: CGSize(width: 1367, height: 769), ceiling: 1080
        )
        #expect(size.width % 2 == 0)
        #expect(size.height % 2 == 0)
    }

    @Test func bitrateFitsThePicture() {
        #expect(VideoRecorder.bitrate(width: 1920, height: 1080) == 2_500_000)
        // A small window gets the floor, not a proportionally starved one.
        #expect(VideoRecorder.bitrate(width: 640, height: 360) == 800_000)
    }
}

/// What doctor says about video. The grant state is a plain Bool here — the
/// real preflight needs a Screen Recording grant of its own to say anything
/// interesting, which is exactly what these tests cannot assume.
struct VideoDoctorTests {
    @Test func enabledWithoutTheGrantWarnsWithARelaunchHint() {
        let check = DoctorReport.checkVideo(granted: false)
        guard case .warn(let message) = check.status else {
            Issue.record("expected a warning, got \(check.status)")
            return
        }
        #expect(message.contains("audio-only"))
        // The relaunch requirement is macOS's, not amanu's, and it is the
        // step people skip — the remediation has to say it.
        #expect(check.remediation?.contains("reopen") == true)
    }

    @Test func enabledAndGrantedIsQuiet() {
        let check = DoctorReport.checkVideo(granted: true)
        guard case .ok = check.status else {
            Issue.record("expected ok, got \(check.status)")
            return
        }
    }
}

struct VideoErrorTests {
    @Test func timeoutErrorHasHelpfulDescription() {
        let error = VideoRecorder.VideoError.timedOut
        #expect(error.description.contains("timed out"))
    }
}

