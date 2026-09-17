import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import amanu

/// The failing real recording, reduced to the writer alone: 1920×1080 at 30
/// fps with real-time pacing, in exactly the configuration the recorder uses.
/// Taking ScreenCaptureKit out of the picture says whether a fault like that
/// one is in the writer's setup or in the buffers the stream hands over.
@Suite(.serialized) struct VideoWriterScaleTests {
    private func sampleBuffer(
        at pts: CMTime, width: Int, height: Int, ioSurface: Bool = false
    ) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        if ioSurface {
            // ScreenCaptureKit hands over IOSurface-backed buffers; a plain
            // CVPixelBuffer is what the control test uses.
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &pixelBuffer)
        } else {
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        }
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
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    @Test func fullSizeFramesWithRealTimePacing() async throws {
        try await run(ioSurface: false, label: "plain")
    }

    /// The shape ScreenCaptureKit actually delivers.
    @Test func fullSizeFramesBackedByAnIOSurface() async throws {
        try await run(ioSurface: true, label: "iosurface")
    }

    /// ScreenCaptureKit sends frames when the picture changes, not on a clock:
    /// bursts with gaps between them, and a presentation timestamp that is the
    /// host clock rather than a frame index. If the encoder's failure lies in
    /// the timing rather than the pixels, this is where it shows.
    @Test func burstyFramesWithARealClock() async throws {
        try await run(ioSurface: true, label: "bursty", bursty: true)
    }

    /// ScreenCaptureKit attaches its own per-frame data (`SCStreamFrameInfo`:
    /// status, display time, content rect, scale factor, dirty rects) to every
    /// sample buffer it hands over. This one carries attachments of that
    /// shape, because they are the last thing about a real stream that a test
    /// can imitate — and the only thing left that the encoder might refuse.
    @Test func framesCarryingStreamAttachments() async throws {
        try await run(ioSurface: true, label: "attachments", attachments: true)
    }

    private func run(
        ioSurface: Bool, label: String, bursty: Bool = false, attachments: Bool = false
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-1080p-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("video.mp4")
        let writer = try VideoFileWriter(
            outputURL: url, width: 1920, height: 1080, frameRate: 30, bitrate: 2_500_000)
        var hostTime = CMTime(value: 1_600_000_000, timescale: 1_000_000_000)
        for frame in 0..<60 {
            let timestamp = bursty
                // Four frames back to back, then a gap — what a screen does.
                ? hostTime + CMTime(value: CMTimeValue(frame % 4), timescale: 30)
                : CMTime(value: CMTimeValue(frame), timescale: 30)
            writer.startSessionIfNeeded(at: timestamp)
            let sample = try sampleBuffer(
                at: timestamp, width: 1920, height: 1080, ioSurface: ioSurface)
            if attachments {
                let frameInfo: [String: Any] = [
                    "SCStreamFrameInfoStatus": 0,
                    "SCStreamFrameInfoDisplayTime": 1.25,
                    "SCStreamFrameInfoScaleFactor": 2.0,
                    "SCStreamFrameInfoContentScale": 2.0,
                    "SCStreamFrameInfoContentRect": [
                        "X": 0.0, "Y": 0.0, "Width": 1920.0, "Height": 1080.0,
                    ],
                    "SCStreamFrameInfoDirtyRects": [
                        ["X": 0.0, "Y": 0.0, "Width": 1920.0, "Height": 1080.0],
                    ],
                ]
                CMSetAttachments(sample, attachments: frameInfo as CFDictionary,
                                 attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            writer.append(sample)
            if !bursty || frame % 4 == 3 {
                hostTime = hostTime + CMTime(value: 1, timescale: 4)
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        let outcome = writer.finalize()
        if case .finished = outcome {} else {
            // Built here rather than inside the macro: the counts are what a
            // failure at this scale is read for.
            let why = "\(label): writer failed at 1080p: \(writer.failureNote ?? "no note")"
                + " (written \(writer.framesWritten), dropped \(writer.framesDropped))"
            Issue.record("\(why)")
        }
    }
}
