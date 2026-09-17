import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
import Testing

@testable import amanu

/// ScreenCaptureKit sends sample buffers that are not pictures: frames whose
/// `SCFrameStatus` is idle, blank, suspended, started or stopped carry no
/// image, and handing one to AVAssetWriter fails the encoder —
/// kVTVideoEncoderMalfunctionErr, -16122 — which is what discarded a whole
/// recorded video on 16 September 2026 while every local imitation of the
/// stream sealed perfectly.
@Suite(.serialized) struct VideoRecorderIncompleteFrameTests {
    /// A screen sample buffer: an image buffer when asked for one, and an
    /// `SCStreamFrameInfo` status attachment like the stream's own.
    private func screenFrame(
        status: Int?, withImage: Bool = true, width: Int = 64, height: Int = 64
    ) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        if withImage {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer!, formatDescriptionOut: &format)
            CMSampleBufferCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer!, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        } else {
            // A status event with no picture at all: an empty block buffer and
            // a video format description, which is what the stream sends.
            CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: kCMVideoCodecType_H264,
                width: Int32(width), height: Int32(height),
                extensions: nil, formatDescriptionOut: &format)
            var block: CMBlockBuffer?
            CMBlockBufferCreateEmpty(
                allocator: kCFAllocatorDefault, capacity: 0, flags: 0, blockBufferOut: &block)
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: format!,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        }

        if let status, let sample {
            let info: [String: Any] = [
                SCStreamFrameInfo.status.rawValue: status,
            ]
            CMSetAttachments(
                sample, attachments: info as CFDictionary,
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sample!
    }

    /// Wait, bounded, for the encoder to have taken at least one frame. A
    /// loaded runner can leave it unready for seconds, and this suite's movies
    /// are one frame long.
    private static func waitForAFrame(_ writer: VideoFileWriter) -> Bool {
        var waited = 0
        while writer.framesWritten == 0, waited < 5_000 {
            usleep(1_000)
            waited += 1
        }
        return writer.framesWritten > 0
    }

    @Test func aCompleteFrameCarryingAPictureIsTaken() {
        #expect(VideoRecorder.isCompleteFrame(screenFrame(status: 0)))
    }

    /// The frames that killed the recording: statuses the stream sends when
    /// nothing has changed, and which carry no image. Named by raw value
    /// rather than by case — the Swift enum omits `stopped` on this SDK while
    /// the C header has it, and the filter reads the raw value the
    /// attachment carries, so the raw values are the honest test.
    @Test func aStatusEventIsNotAFrame() {
        for raw in 1...5 {
            let event = screenFrame(status: raw, withImage: false)
            #expect(!VideoRecorder.isCompleteFrame(event), "status \(raw) must not count")
        }
    }

    /// A complete status with no picture is no better than an idle one.
    @Test func aCompleteStatusWithoutAPictureIsStillNotAFrame() {
        #expect(!VideoRecorder.isCompleteFrame(screenFrame(status: 0, withImage: false)))
    }

    /// No attachment at all is not evidence of an event: the picture is the
    /// test then, which is how a stream that attaches nothing still records.
    @Test func withoutAStatusThePictureDecides() {
        #expect(VideoRecorder.isCompleteFrame(screenFrame(status: nil, withImage: true)))
        #expect(!VideoRecorder.isCompleteFrame(screenFrame(status: nil, withImage: false)))
    }

    /// And the writer itself refuses a buffer with no picture, whatever got
    /// past the stream: dropping the frame leaves the recording sealable.
    @Test func theWriterDropsAPicturelessBufferAndStillSeals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-video-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = try VideoFileWriter(
            outputURL: dir.appendingPathComponent("video.mp4"),
            width: 64, height: 64, frameRate: 30, bitrate: 300_000)
        writer.startSessionIfNeeded(at: .zero)
        let picture = screenFrame(status: 0)
        writer.append(picture)
        #expect(writer.quiesce())
        // `quiesce` says the writer's queue is drained, not that the encoder has
        // taken the frame — and a file with nothing in it is deleted by design,
        // so the picture has to be in before the seal is asked about.
        guard Self.waitForAFrame(writer) else {
            Issue.record("the picture was never encoded, so there is no file to seal")
            return
        }
        let accepted = writer.framesWritten

        // The buffer that used to fail the encoder.
        writer.append(screenFrame(status: 1, withImage: false))
        #expect(writer.quiesce())

        #expect(writer.framesWritten == accepted, "the pictureless frame added nothing")
        #expect(writer.framesDropped >= 1)
        if case .finished = writer.finalize() {
        } else {
            Issue.record("a dropped pictureless frame must not cost the file")
        }
    }
}
