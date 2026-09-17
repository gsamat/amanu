import AVFoundation
import CoreMedia
import Foundation
import os.lock

/// Writes video sample buffers into a progressively-growing MP4. All the
/// writer state lives on one serial queue — the same queue the stream
/// callbacks arrive on — because `AVAssetWriterInput` is not documented as
/// thread-safe and a finalize racing an append would be a crash nobody can
/// reproduce.
///
/// The file is not playable until `finalize` runs: AVAssetWriter writes the
/// moov atom at the very end, so a crash mid-meeting loses the video however
/// the buffers were written. Audio CAFs stay the durable artifact.
final class VideoFileWriter: @unchecked Sendable {
    enum WriterError: Error, CustomStringConvertible {
        case cannotAddVideoInput
        case writingNeverStarted(Error?)

        var description: String {
            switch self {
            case .cannotAddVideoInput:
                return "video writer refused its input"
            case .writingNeverStarted(let error):
                return "video writer could not start: \(error.map(String.init(describing:)) ?? "unknown reason")"
            }
        }
    }

    /// What a finalize found. `empty` means no session ever started (or no
    /// frame was ever appended) — the half-written file has been deleted, and
    /// there is nothing honest to put in meta.json.
    enum Outcome: Equatable {
        case finished(framesWritten: Int, framesDropped: Int)
        case empty
        case timedOut
    }

    /// Why the last finalize did not produce a playable file, in words, for
    /// the session log. The writer's own messages go to stderr, which a
    /// LaunchServices-launched app throws away — a video that failed to
    /// finalize used to leave no trace anywhere a person could find it.
    private(set) var failureNote: String?

    private let outputURL: URL
    private let queue = DispatchQueue(label: "me.samat.amanu.video-writer")
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    /// The one size this file's encoder will accept. Anything else is
    /// dropped: an H.264 session has a fixed size for life, and handing the
    /// encoder a frame that disagrees fails the whole recording (-16122,
    /// measured on 16 September 2026).
    private let width: Int
    private let height: Int
    /// Frames waiting for the encoder, confined to `queue`. Hardware H.264
    /// keeps this empty in practice; it exists so a brief encoder stall costs
    /// a short buffer, not a hole in the meeting.
    private var pending: [CMSampleBuffer] = []
    /// ~half a second of 30 fps. Past this the machine cannot keep up and the
    /// newest frames are dropped: a live edge beats a stale one.
    private static let pendingLimit = 15

    struct Counters {
        var framesWritten = 0
        var framesDropped = 0
        var sessionStarted = false
        var finished = false
    }
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    var framesWritten: Int { counters.withLock { $0.framesWritten } }
    var framesDropped: Int { counters.withLock { $0.framesDropped } }

    init(outputURL: URL, width: Int, height: Int, frameRate: Int, bitrate: Int) throws {
        self.outputURL = outputURL
        self.width = width
        self.height = height

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // H.264, not HEVC: every Mac above the floor can encode it, and on
        // Intel machines without Quick Sync the software HEVC encoder would
        // eat the CPU a meeting needs for everything else.
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw WriterError.cannotAddVideoInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.writingNeverStarted(writer.error)
        }
        self.writer = writer
        self.input = input
    }

    /// Hand the encoder everything it will take, in order. Runs on `queue`.
    private func appendPendingWhileReady() {
        while input.isReadyForMoreMediaData, !pending.isEmpty {
            let buffer = pending.removeFirst()
            if input.append(buffer) {
                counters.withLock { $0.framesWritten += 1 }
            } else {
                noteAppendFailure()
                counters.withLock { $0.framesDropped += 1 }
            }
        }
    }

    /// Remember why the encoder would not take a frame — the reason the whole
    /// recording is about to be discarded, and the reason nothing else could
    /// report: AVFoundation puts the real cause in the writer's error, and the
    /// writer's own messages go to a stderr nobody sees. The first refusal is
    /// the informative one; the rest are consequences of it.
    private func noteAppendFailure() {
        guard failureNote == nil else { return }
        let reason = writer.error.map(String.init(describing:)) ?? "no error given"
        failureNote = "the encoder refused a frame: \(reason)"
    }

    /// A pump is already waiting; it will pick the queue back up when it
    /// fires. Confined to `queue`.
    private var pumpScheduled = false

    /// Re-check readiness shortly. The encoder consumes asynchronously, so a
    /// "not ready" answer lasts milliseconds — far shorter than the gap
    /// between real frames, and the reason this file never starves in
    /// production. Runs on `queue`.
    private func drainSoon() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + 0.005) { [self] in
            pumpScheduled = false
            appendPendingWhileReady()
            if !pending.isEmpty { drainSoon() }
        }
    }

    /// Begin the movie's timeline at the first frame's own presentation
    /// timestamp, so the file's clock is the capture clock and the
    /// `video_start_offset_ms` meta field has something true to point at.
    /// Returns true only for the call that actually started it. The session
    /// start is enqueued ahead of any append the same caller makes next — the
    /// queue is FIFO and the callbacks arrive on it in order.
    @discardableResult
    func startSessionIfNeeded(at sourceTime: CMTime) -> Bool {
        let shouldStart = counters.withLock { state -> Bool in
            guard !state.sessionStarted, !state.finished else { return false }
            state.sessionStarted = true
            return true
        }
        guard shouldStart else { return false }
        queue.async { [self] in
            writer.startSession(atSourceTime: sourceTime)
        }
        return true
    }

    /// Queue one frame for the encoder. Frames whose pending buffer is full
    /// are dropped, not queued: this is real-time capture, and falling behind
    /// the meeting is a worse file than a sparser one.
    func append(_ sampleBuffer: CMSampleBuffer) {
        // The buffer is born on the stream's callback queue and lives on in
        // the writer's pending list — one confinement chain the type system
        // cannot see, so it is stated here rather than smuggled.
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [self] in
            let (started, finished) = counters.withLock { ($0.sessionStarted, $0.finished) }
            guard started, !finished, writer.status == .writing else {
                counters.withLock { $0.framesDropped += 1 }
                return
            }
            // A frame without pixels, or of another size, cannot go into this file.
            // Dropping it costs one frame; feeding it to the encoder costs the video (-16122).
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
                counters.withLock { $0.framesDropped += 1 }
                return
            }
            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
            guard bufferWidth == self.width, bufferHeight == self.height else {
                counters.withLock { $0.framesDropped += 1 }
                return
            }
            if pending.count >= Self.pendingLimit {
                counters.withLock { $0.framesDropped += 1 }
                return
            }
            if !input.isReadyForMoreMediaData {
                pending.append(buffer)
                drainSoon()
                return
            }
            if input.append(buffer) {
                counters.withLock { $0.framesWritten += 1 }
            } else {
                noteAppendFailure()
                counters.withLock { $0.framesDropped += 1 }
            }
        }
    }

    /// Wait until every append enqueued so far has had its turn on the
    /// writer's queue. Tests need this — their loop is a faster producer than
    /// any meeting — and nothing else does.
    @discardableResult
    func quiesce(timeout: TimeInterval = 5) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Stop accepting frames and write the moov atom — synchronously, because
    /// a recording is not stopped until its file is playable. Must not be
    /// called from `queue` (it waits on that queue's work). The empty-or-not
    /// decision is made on the queue, behind every append already enqueued —
    /// counted from the caller's side it would race the last frames and
    /// delete a file that has an hour of meeting in it. A file with no frames
    /// is cancelled and deleted rather than left as junk that looks like a
    /// recording.
    func finalize(timeout: TimeInterval = 15) -> Outcome {
        let alreadyFinished = counters.withLock {
            let was = $0.finished
            $0.finished = true
            return was
        }
        guard !alreadyFinished else { return .empty }

        final class Result: @unchecked Sendable {
            var outcome: Outcome = .empty
        }
        let result = Result()
        let done = DispatchSemaphore(value: 0)

        queue.async { [self] in
            // Flush whatever the encoder will still take before sealing; a
            // frame still pending at this point has nowhere to go, and it is
            // counted as dropped rather than vanishing from the books.
            appendPendingWhileReady()
            if !pending.isEmpty {
                counters.withLock { $0.framesDropped += pending.count }
                pending.removeAll()
            }
            let (started, wrote) = counters.withLock { ($0.sessionStarted, $0.framesWritten) }
            if started, wrote > 0 {
                input.markAsFinished()
                writer.finishWriting { [self] in
                    result.outcome = .finished(
                        framesWritten: wrote,
                        framesDropped: self.framesDropped
                    )
                    done.signal()
                }
            } else {
                // Nothing ever rendered — a permission silently missing or a
                // stream that delivered nothing. cancelWriting, then delete
                // the husk: an unplayable file in a session folder reads as
                // "the recording is here" to everyone who looks later.
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                failureNote = started
                    ? "no frames were ever encoded"
                    : "the encoder never accepted a frame"
                result.outcome = .empty
                done.signal()
            }
        }

        guard done.wait(timeout: .now() + timeout) == .success else {
            failureNote = "the movie did not finish writing within \(Int(timeout))s"
            FileHandle.standardError.write(Data(
                "video: writer did not finish within \(Int(timeout))s — deleting the unplayable file\n".utf8
            ))
            // Off `queue`, deliberately, and the one place this type touches
            // its writer from outside it: the only way here is that the queue
            // is wedged behind a `finishWriting` that never came back, so
            // cleanup enqueued behind it would never run and the unplayable
            // file would stay where everything later reads it as a recording.
            // `cancelWriting` is safe from any thread and is what unblocks it.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return .timedOut
        }

        if case .finished = result.outcome, writer.status != .completed {
            failureNote = "the movie ended in state \(writer.status.rawValue)"
                + (writer.error.map { ": \($0)" } ?? "")
            FileHandle.standardError.write(Data(
                "video: writer finished in state \(writer.status.rawValue) — deleting the unplayable file\n".utf8
            ))
            try? FileManager.default.removeItem(at: outputURL)
            return .empty
        }
        return result.outcome
    }
}
