import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os.lock
@preconcurrency import ScreenCaptureKit

/// The video track: one ScreenCaptureKit stream pointed at the meeting window
/// (or the main display when no window can be picked out), writing H.264 into
/// the session folder through `VideoFileWriter`.
///
/// The stream is deliberately video-only. Audio keeps flowing through the
/// process tap and the mic engine, whose restart, echo-cancellation and
/// route-following behaviour an SCStream audio tap does not have (rca-003);
/// a second audio path here would be two recordings of one meeting, not a
/// better one.
final class VideoRecorder: NSObject, @unchecked Sendable {
    enum VideoError: Error, CustomStringConvertible {
        case nothingToCapture
        case windowDisappeared(CGWindowID)
        case displayDisappeared(CGDirectDisplayID)
        /// The stream started and delivered no frames at all — the shape a
        /// missing Screen Recording grant takes, and the only honest test of
        /// it there is.
        case nothingDelivered
        case timedOut

        var description: String {
            switch self {
            case .nothingToCapture:
                return "no display available to record"
            case .nothingDelivered:
                return "the screen capture delivered no frames — check Screen Recording in "
                    + "System Settings → Privacy & Security → Screen & System Audio Recording "
                    + "(the pane shows the state whatever this program thinks), then quit and "
                    + "reopen amanu"
            case .windowDisappeared(let id):
                return "the meeting window (id \(id)) vanished between listing and capture"
            case .displayDisappeared(let id):
                return "display \(id) vanished between listing and capture"
            case .timedOut:
                return "screen capture initialization timed out"
            }
        }
    }

    struct Configuration: Sendable {
        let outputURL: URL
        /// A ceiling, not a target: nothing is ever upscaled past what the
        /// source actually shows, and everything is scaled to an even height
        /// because H.264 refuses odd dimensions.
        let height: Int
        let mode: VideoCaptureMode
        let families: [String]
        var frameRate: Int = 30
    }

    private let queue = DispatchQueue(label: "me.samat.amanu.video")

    private struct Locked: @unchecked Sendable {
        var isRecording = false
        var isMuted = false
        var stoppedWithError = false
        var firstBufferAt: Date?
        var stream: SCStream?
        var writer: VideoFileWriter?
        /// What the stream was built to capture, and what it is capturing
        /// now — `target` moves when a re-pick finds a better window.
        var config: Configuration?
        var target: VideoCaptureTarget?
        /// The user chose the content in the system picker: the automatic
        /// re-pick stands down, and their changes arrive as filters.
        var pickerDriven = false
        /// The size SCStreamConfiguration asked for, kept only so the first
        /// frame can be reported against it. The writer takes its dimensions
        /// from the frame itself, never from this.
        var requestedSize: (width: Int, height: Int)?
        /// The writer's own dimensions, once the first frame settled them.
        var frameSize: (width: Int, height: Int)?
        var sizeChangeReported = false
    }
    private let state = OSAllocatedUnfairLock(initialState: Locked())

    var isRecording: Bool { state.withLock { $0.isRecording } }
    /// Wall-clock moment the first frame was appended — the track's true
    /// start, read by the session for `video_start_offset_ms`.
    var firstBufferAt: Date? { state.withLock { $0.firstBufferAt } }
    /// True once the stream reported it died on its own. The session's
    /// liveness tick turns this into a notification — a deterministic signal,
    /// unlike file growth, which a static window or a locked screen would
    /// freeze without anything being wrong.
    var stoppedWithError: Bool { state.withLock { $0.stoppedWithError } }

    /// Frames the writer has accepted. Zero some seconds after a start means
    /// macOS is not letting us read the screen — the signal this class uses
    /// instead of a permission check that can disagree with System Settings.
    var framesWritten: Int { state.withLock { $0.writer?.framesWritten ?? 0 } }

    /// Whether the stream is pointed at a window that may be replaced by a
    /// better one — the tick re-runs the pick only for window capture; a
    /// display never moves. A picker-driven stream is excluded too: the user
    /// chose their content, and the system picker delivers any change they
    /// make later as a new filter.
    var followingWindow: Bool {
        state.withLock { $0.isRecording && $0.config?.mode == .window && !$0.pickerDriven }
    }

    /// Whether this capture was chosen by the person in the system picker.
    var pickerDriven: Bool { state.withLock { $0.pickerDriven } }

    /// While muted, frames are dropped instead of appended. The stream keeps
    /// running and its presentation timestamps keep advancing, so the video
    /// stays aligned to the wall clock across a pause — the file shows a jump
    /// cut, which is the honest picture of a meeting with a hole in it.
    var isMuted: Bool {
        get { state.withLock { $0.isMuted } }
        set { state.withLock { $0.isMuted = newValue } }
    }

    /// List shareable content, pick the target, build the stream, start it.
    /// `prebuiltFilter` is content the person chose in the system picker:
    /// when given, the automatic pick stands down, the tick stops re-running,
    /// and their later changes arrive through `apply`.
    /// A missing permission is deliberately not thrown from here: the stream
    /// starts, delivers nothing, and `RecordingSession.startVideo` reports
    /// that instead — the preflight has been seen to lie.
    func start(
        _ config: Configuration, prebuiltFilter: SCContentFilter? = nil
    ) throws {
        guard !isRecording else { return }

        // Deliberately no `CGPreflightScreenCaptureAccess` refusal here. It
        // has been seen to answer "not granted" on a Mac whose System
        // Settings pane shows amanu allowed, and refusing on a possibly-wrong
        // answer costs the recording its picture. What is true is whether
        // frames arrive: `RecordingSession.startVideo` watches for that and
        // reports a stream macOS never let us read.

        let filter: SCContentFilter
        let target: VideoCaptureTarget?
        let pickerDriven: Bool
        if let prebuiltFilter {
            // The person chose this content themselves; the stream starts on
            // it, and the system picker — still attached — brings any change
            // they make later straight to `apply`.
            filter = prebuiltFilter
            target = nil
            pickerDriven = true
        } else {
            let content = try Self.sync {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            let candidates = content.windows.map { window in
                VideoWindowCandidate(
                    windowID: window.windowID,
                    owningBundleID: window.owningApplication?.bundleIdentifier,
                    isOnScreen: window.isOnScreen,
                    frame: window.frame,
                    layer: window.windowLayer,
                    isActive: window.isActive
                )
            }
            let displays = content.displays.map { VideoDisplayCandidate(displayID: $0.displayID) }
            guard
                let picked = VideoWindowPicker.choose(
                    windows: candidates, displays: displays,
                    families: config.families, mode: config.mode
                )
            else { throw VideoError.nothingToCapture }
            target = picked
            pickerDriven = false
            switch picked {
            case .window(let id, _):
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    throw VideoError.windowDisappeared(id)
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw VideoError.displayDisappeared(id)
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
        }

        // pointPixelScale turns the captured rect's point size into what will
        // actually be delivered — 2 on a Retina display, 1 elsewhere. The
        // writer takes its true size from the first delivered frame, so this
        // is a request, not a promise the stream is held to.
        let scale = CGFloat(filter.pointPixelScale)
        let sourcePixels = CGSize(
            width: filter.contentRect.width * scale,
            height: filter.contentRect.height * scale
        )

        let (width, height) = Self.outputSize(sourcePixels: sourcePixels, ceiling: config.height)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(config.frameRate)
        )
        streamConfig.queueDepth = 8
        streamConfig.showsCursor = true
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        // Scale the source into the configured size rather than letting the
        // source rect decide it. This matters because the filter can be
        // swapped mid-recording (following the meeting window): without it a
        // new window with a different size can change what the encoder
        // receives, and an H.264 session has one fixed size for its whole
        // life — a mismatch ends as a failed writer and a discarded file.
        streamConfig.scalesToFit = true
        // The whole point of this class: the audio tracks come from the tap
        // and the mic engine, and this stream must never grow its own.
        streamConfig.capturesAudio = false

        // No writer yet: its dimensions come from the first frame that
        // actually arrives. Building it from the filter's geometry instead —
        // which is what this did — guesses at what ScreenCaptureKit will
        // deliver, and a guess that is wrong ends as an encoder failure
        // (-16122) and a video file deleted at stop.
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try Self.sync {
            try await stream.startCapture()
        }

        state.withLock {
            $0.stream = stream
            $0.writer = nil
            $0.config = config
            $0.target = target
            $0.pickerDriven = pickerDriven
            $0.requestedSize = (width, height)
            $0.frameSize = nil
            $0.sizeChangeReported = false
            $0.isRecording = true
        }
    }

    /// Swap what the stream captures without restarting it — the system
    /// picker delivers a new filter when the person changes their selection
    /// mid-meeting, and the video follows without a timestamp break.
    func apply(filter: SCContentFilter) async throws {
        guard let stream = state.withLock({ $0.stream }) else { return }
        try await stream.updateContentFilter(filter)
    }

    /// Re-run the window choice against the families the session follows
    /// now — a second call app can join mid-meeting, and the meeting window
    /// itself usually opens *after* recording begins, which is how a
    /// launcher ends up recorded instead of the meeting. When the best
    /// target differs from the one captured, the stream's filter is swapped
    /// in place: same writer, same dimensions, timestamps continue, so the
    /// file stays one recording. Returns a description of the new target,
    /// or nil when nothing changed (or the update could not happen — a
    /// running recording is never failed by a re-pick).
    func follow(families: [String]) async -> String? {
        let (recording, config, current) = state.withLock {
            ($0.isRecording, $0.config, $0.target)
        }
        guard recording, let config, config.mode == .window else { return nil }

        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        else { return nil }
        let candidates = content.windows.map { window in
            VideoWindowCandidate(
                windowID: window.windowID,
                owningBundleID: window.owningApplication?.bundleIdentifier,
                isOnScreen: window.isOnScreen,
                frame: window.frame,
                layer: window.windowLayer,
                isActive: window.isActive
            )
        }
        let displays = content.displays.map { VideoDisplayCandidate(displayID: $0.displayID) }
        guard
            let target = VideoWindowPicker.choose(
                windows: candidates, displays: displays,
                families: families, mode: config.mode
            )
        else { return nil }
        guard target != current else { return nil }

        // Bound locally: `stream` the property collides with the global
        // `stream(_:didOutputSampleBuffer:of:)` inside this type's conformances.
        let currentStream = state.withLock { $0.stream }
        do {
            switch target {
            case .window(let id, _):
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    return nil
                }
                try await currentStream?.updateContentFilter(
                    SCContentFilter(desktopIndependentWindow: window))
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    return nil
                }
                try await currentStream?.updateContentFilter(
                    SCContentFilter(display: display, excludingWindows: []))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "video: re-pick to \(target) failed, keeping the current window: \(error)\n"
                    .utf8))
            return nil
        }

        state.withLock { $0.target = target }
        switch target {
        case .window(_, let bundleID): return "window \(bundleID)"
        case .display(let id): return "display \(id)"
        }
    }

    /// What a stop produced — what meta.json says about the video depends on
    /// it: only a finished outcome leaves a file worth naming.
    struct Summary {
        let outcome: VideoFileWriter.Outcome
        let framesWritten: Int
        let framesDropped: Int
        /// Why there is no playable file, when there is none, in words the
        /// session log can carry. The writer's own messages go to stderr,
        /// which a bundled app never shows anyone.
        let failureNote: String?

        /// Whether a playable file exists at `video.mp4`.
        var isFinished: Bool {
            if case .finished = outcome { return true }
            return false
        }
    }

    /// Stop delivery, then finalize the file — synchronously, like every
    /// other recorder's stop, because a session folder without a playable
    /// video.mp4 must not pretend the video is there. Idempotent; nil when
    /// video was never started.
    func stop() -> Summary? {
        let (stream, writer, wasRecording) = state.withLock {
            current -> (SCStream?, VideoFileWriter?, Bool) in
            let was = current.isRecording
            current.isRecording = false
            let pair = (current.stream, current.writer)
            current.stream = nil
            current.writer = nil
            return (pair.0, pair.1, was)
        }
        // Never started — an ordinary audio-only session, with nothing to say.
        guard wasRecording else { return nil }

        if let stream {
            // Stop delivery first: after this completes no further screen
            // buffers arrive, so finalize seals the file at the true end.
            nonisolated(unsafe) let stopping = stream
            let delivered = DispatchSemaphore(value: 0)
            Task.detached {
                try? await stopping.stopCapture()
                delivered.signal()
            }
            _ = delivered.wait(timeout: .now() + 5)
            try? stream.removeStreamOutput(self, type: .screen)
        }
        guard let writer else {
            // It was recording, but no frame ever arrived, so no writer was
            // ever built and no file exists. Say that rather than returning
            // nothing, which is what "video was never started" means.
            return Summary(
                outcome: .empty,
                framesWritten: 0,
                framesDropped: 0,
                failureNote: "the screen capture never delivered a frame"
            )
        }
        let outcome = writer.finalize()
        return Summary(
            outcome: outcome,
            framesWritten: writer.framesWritten,
            framesDropped: writer.framesDropped,
            failureNote: writer.failureNote
        )
    }

    // MARK: - sizing and rate, pure so they can be tested

    /// Scale the source down to the ceiling, preserving aspect, never up, and
    /// never odd — H.264 encodes even dimensions only.
    static func outputSize(sourcePixels: CGSize, ceiling: Int) -> (width: Int, height: Int) {
        guard sourcePixels.width > 0, sourcePixels.height > 0 else { return (2, 2) }
        let scale = min(1, CGFloat(ceiling) / sourcePixels.height)
        let width = max(2, Int(sourcePixels.width * scale) & ~1)
        let height = max(2, Int(sourcePixels.height * scale) & ~1)
        return (width, height)
    }

    /// ~2.5 Mbps at 1080p, scaled by area, floored low enough that a tiny
    /// window still gets a legible picture.
    static func bitrate(width: Int, height: Int) -> Int {
        max(800_000, Int(2_500_000 * Double(width * height) / Double(1920 * 1080)))
    }

    /// Bridge an async API into synchronous code. The recorders' `start` is
    /// synchronous by contract — a session either starts, with all its
    /// tracks, or throws before the manifest is written — and these two
    /// ScreenCaptureKit calls are its only asynchronous ingredients.
    private static func sync<T>(
        timeout: TimeInterval = 10,
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = BridgedBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = try await work() } catch { box.error = error }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw VideoError.timedOut
        }
        if let failure = box.error { throw failure }
        guard let result = box.value else { throw VideoError.nothingToCapture }
        return result
    }
}

/// A local class cannot live inside a generic function, so the hand-off box
/// for `sync` lives here instead.
private final class BridgedBox<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
    init() {}
}

extension VideoRecorder: SCStreamOutput, SCStreamDelegate {
    /// Whether a sample buffer carries a complete video frame rather than a
    /// stream lifecycle event (.started, .stopped) or a static gap (.idle, .blank).
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[AnyHashable: Any]],
            let attachments = attachmentsArray.first
        else {
            return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
        }
        let statusRaw = (attachments[SCStreamFrameInfo.status] as? Int)
            ?? (attachments[SCStreamFrameInfo.status.rawValue] as? Int)
        if let statusRaw, let status = SCFrameStatus(rawValue: statusRaw) {
            return status == .complete
        }
        return CMSampleBufferGetImageBuffer(sampleBuffer) != nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard state.withLock({ $0.isRecording && !$0.isMuted }) else { return }

        // Filter out incomplete frames (.started, .idle, .blank, .suspended, .stopped).
        // ScreenCaptureKit delivers these lifecycle and status events as sample
        // buffers without valid pixel data; passing them to the encoder causes
        // AVAssetWriter to fail with OSStatus -16122 (kVTVideoEncoderMalfunctionErr).
        guard Self.isCompleteFrame(sampleBuffer) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufferWidth > 1, bufferHeight > 1 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // The first frame decides the file's size, because it is the only
        // thing that knows what ScreenCaptureKit actually delivers. A writer
        // built on a guess dies later with the encoder refusing every frame
        // (-16122), taking the whole video with it.
        if state.withLock({ $0.writer }) == nil {
            guard let config = state.withLock({ $0.config }) else { return }
            do {
                let writer = try VideoFileWriter(
                    outputURL: config.outputURL,
                    width: bufferWidth,
                    height: bufferHeight,
                    frameRate: config.frameRate,
                    bitrate: Self.bitrate(width: bufferWidth, height: bufferHeight)
                )
                let requested = state.withLock { $0.requestedSize }
                state.withLock {
                    $0.writer = writer
                    $0.frameSize = (bufferWidth, bufferHeight)
                }
                let fourCC = CMSampleBufferGetFormatDescription(sampleBuffer)
                    .map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
                appendSessionLog(
                    "video: first frame \(bufferWidth)×\(bufferHeight)"
                        + " · format \(fourCC)"
                        + (requested.map { " · asked the stream for \($0.width)×\($0.height)" } ?? ""),
                    to: config.outputURL.deletingLastPathComponent())
            } catch {
                state.withLock { $0.stoppedWithError = true }
                appendSessionLog(
                    "video writer did not start: \(error)",
                    to: config.outputURL.deletingLastPathComponent())
                return
            }
        }

        // A frame in another size cannot go into this file — one H.264
        // session, one size — so it is dropped and reported once rather than
        // fed to an encoder that would fail the whole recording over it.
        if let size = state.withLock({ $0.frameSize }) {
            guard bufferWidth == size.width, bufferHeight == size.height else {
                let first = state.withLock { current -> Bool in
                    defer { current.sizeChangeReported = true }
                    return !current.sizeChangeReported
                }
                if first, let config = state.withLock({ $0.config }) {
                    appendSessionLog(
                        "video: the captured window changed size to "
                            + "\(bufferWidth)×\(bufferHeight) — frames that size are dropped",
                        to: config.outputURL.deletingLastPathComponent())
                }
                return
            }
        }

        guard let writer = state.withLock({ $0.writer }) else { return }
        if writer.startSessionIfNeeded(at: pts) {
            state.withLock { $0.firstBufferAt = Date() }
        }
        writer.append(sampleBuffer)
    }

    /// A stream that died mid-meeting has no second act; recording the fact
    /// lets the session say so while it still matters, and saying so once, in
    /// the log, keeps the gap diagnosable after the fact.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        state.withLock { $0.stoppedWithError = true }
        FileHandle.standardError.write(Data(
            "video: stream stopped unexpectedly: \(error)\n".utf8
        ))
    }

    /// '420v' as a number is "420v" as a string — the four bytes of the
    /// FourCC, read in order. It names, in the session log, which pixel
    /// format a stream actually delivered, which is the one thing about a
    /// capture that can be neither predicted nor reproduced off-stream.
    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}
