import AVFoundation
import CoreMedia
import Foundation

/// Merges a session's video and audio into one file — `meeting.mp4` — while
/// leaving every source exactly where it was. The audio files stay because
/// they are the durable artifact (a crash takes the video, never the audio),
/// and video.mp4 stays because the merge is derived and a person may want the
/// silent original.
///
/// As fast as the format allows, and deliberately built from the two pieces
/// the rest of this program already trusts. The audio is mixed by
/// `TrackCompressor.encodeStereo` — the same code the keep_audio archive
/// uses, reading frames through `AVAudioFile` and asking macOS for nothing.
/// The picture is then remuxed, not re-encoded: compressed H.264 samples pass
/// through an `AVAssetReader` into an `AVAssetWriter` untouched, so the merge
/// costs disk speed rather than encoder time. The export session is not
/// involved, for the reason `AudioMixer` documents at length — it makes macOS
/// ask for Photos and Music access, which is absurd for a meeting recorder.
enum VideoMerger {
    enum MergeError: Error, CustomStringConvertible {
        case videoTrackMissing(URL)
        case audioTrackMissing(URL)
        case writeFailed(Error?)
        /// A sample the merge had to place and could not. Counted as a
        /// failure rather than skipped: the file would still seal, and a
        /// `meeting.mp4` with a hole in it reads as complete.
        case frameNotWritten(String)

        var description: String {
            switch self {
            case .videoTrackMissing(let url): return "no video track in \(url.lastPathComponent)"
            case .audioTrackMissing(let url): return "no audio track in \(url.lastPathComponent)"
            case .writeFailed(let error):
                return "the merged file could not be written: \(error.map(String.init(describing:)) ?? "unknown reason")"
            case .frameNotWritten(let what):
                return "\(what) would not take a frame — the merged file would have had holes in it"
            }
        }
    }

    /// Build `meeting.mp4`: stereo audio (mic left, system right) on the
    /// shared clock that starts at zero, with the video laid in
    /// `videoOffsetMs` later — the same clock meta.json records for every
    /// track. Runs off the cooperative pool at utility priority: this is
    /// disk-bound work over a gigabyte, and a recording may be starting.
    @discardableResult
    static func merge(
        video: URL,
        videoOffsetMs: Int,
        mic: TrackCompressor.StereoTrack?,
        system: TrackCompressor.StereoTrack?,
        to output: URL
    ) async throws -> URL {
        try await Task.detached(priority: .utility) { () -> URL in
            let mix = output.deletingLastPathComponent()
                .appendingPathComponent("meeting.tmp.m4a")
            let partial = output.deletingLastPathComponent()
                .appendingPathComponent("meeting.tmp.mp4")
            defer {
                // The mix is derived and the partial is worthless: a merge
                // that ends — well or badly — leaves neither behind.
                try? FileManager.default.removeItem(at: mix)
                try? FileManager.default.removeItem(at: partial)
            }

            // Stage 1 — the audio. Written to a temp name and only renamed
            // once the remux has used it, so an interrupted merge never
            // leaves a meeting.mp4 someone mistakes for complete.
            _ = try TrackCompressor.encodeStereo(mic: mic, system: system, to: mix)
            try await remux(video: video, videoOffsetMs: videoOffsetMs, audio: mix,
                to: partial)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
            return output
        }.value
    }

    // MARK: - the remux

    /// Copy the compressed samples of one video track and one audio track
    /// into a single MP4 — no decoding, no encoding, two files read and one
    /// written. The video's presentation times are shifted onto the audio's
    /// clock, which is the timeline the transcript already speaks.
    private static func remux(
        video: URL, videoOffsetMs: Int, audio: URL, to output: URL
    ) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MergeError.videoTrackMissing(video)
        }
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MergeError.audioTrackMissing(audio)
        }

        let videoReader = try AVAssetReader(asset: videoAsset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoReader.add(videoOutput)
        let audioReader = try AVAssetReader(asset: audioAsset)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioReader.add(audioOutput)

        try? FileManager.default.removeItem(at: output)
        // Passthrough into MP4 wants to know what it will receive before the
        // first sample arrives. `sourceFormatHint` — the source track's own
        // format description — is the honest statement of what this remux is:
        // the same bytes, a new container. (A full outputSettings dictionary
        // would mean re-encoding, the opposite of the point.)
        guard let videoDescription = try await videoTrack.load(.formatDescriptions).first else {
            throw MergeError.videoTrackMissing(video)
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: videoDescription)
        guard let audioDescription = try await audioTrack.load(.formatDescriptions).first else {
            throw MergeError.audioTrackMissing(audio)
        }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil, sourceFormatHint: audioDescription)
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false

        let writer = try AVAssetWriter(url: output, fileType: .mp4)
        writer.add(videoInput)
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw MergeError.writeFailed(writer.error)
        }
        videoReader.startReading()
        audioReader.startReading()
        // The audio mix starts at zero by construction, so the session does
        // too, and the video lands `videoOffsetMs` into it.
        writer.startSession(atSourceTime: .zero)

        var videoFinished = false
        var audioFinished = false

        // One loop, both tracks: feed whichever input is ready, sleep 10 ms
        // when neither is. The straight-line shape is MediaNormalizer's, the
        // one pump in this program measured to finish; the two-thread and
        // requestMediaDataWhenReady shapes were tried first and wedged —
        // the writer sat in .writing forever with both readers completed.
        //
        // Every append is checked, as it is there: an input that refuses a
        // sample is how a file ends up sealed, playable and missing the frames
        // nobody counted, which is worse than a merge that fails and keeps the
        // originals (which is what `merge_failed` means).
        func place(_ sample: CMSampleBuffer, in input: AVAssetWriterInput, what: String) throws {
            guard input.append(sample) else {
                writer.cancelWriting()
                guard let reason = writer.error else {
                    throw MergeError.frameNotWritten(what)
                }
                throw MergeError.writeFailed(reason)
            }
        }
        while !videoFinished || !audioFinished {
            var fed = false
            if !videoFinished {
                if videoReader.status == .reading {
                    if videoInput.isReadyForMoreMediaData,
                       let sample = videoOutput.copyNextSampleBuffer() {
                        // Retiming allocates, so it can fail; a frame the merge
                        // cannot place is a frame it must not lose.
                        if videoOffsetMs != 0 {
                            guard let moved = shifted(sample, byMs: videoOffsetMs) else {
                                videoInput.markAsFinished()
                                writer.cancelWriting()
                                throw MergeError.frameNotWritten("the video stream")
                            }
                            try place(moved, in: videoInput, what: "the video track")
                        } else {
                            try place(sample, in: videoInput, what: "the video track")
                        }
                        fed = true
                    }
                } else if videoReader.status != .unknown {
                    videoInput.markAsFinished()
                    videoFinished = true
                }
            }
            if !audioFinished {
                if audioReader.status == .reading {
                    if audioInput.isReadyForMoreMediaData,
                       let sample = audioOutput.copyNextSampleBuffer() {
                        try place(sample, in: audioInput, what: "the audio track")
                        fed = true
                    }
                } else if audioReader.status != .unknown {
                    audioInput.markAsFinished()
                    audioFinished = true
                }
            }

            if videoReader.status == .failed || audioReader.status == .failed {
                break
            }

            if fed {
                await Task.yield()
            } else {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        // A reader that ended in failure poisons the file; surface it rather
        // than sealing half a movie.
        if videoReader.status == .failed {
            writer.cancelWriting()
            throw MergeError.writeFailed(videoReader.error)
        }
        if audioReader.status == .failed {
            writer.cancelWriting()
            throw MergeError.writeFailed(audioReader.error)
        }
        // Out of the loop, ensure both inputs are marked finished.
        if !videoFinished { videoInput.markAsFinished() }
        if !audioFinished { audioInput.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MergeError.writeFailed(writer.error)
        }
    }

    /// The same samples on a later clock. The decode timestamp moves with the
    /// presentation timestamp, or the encoder order — which passthrough
    /// preserves — would contradict the timeline it lands on.
    private static func shifted(_ buffer: CMSampleBuffer, byMs ms: Int) -> CMSampleBuffer? {
        let offset = CMTime(value: CMTimeValue(ms), timescale: 1000)
        let decode = CMSampleBufferGetDecodeTimeStamp(buffer)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(buffer) + offset,
            decodeTimeStamp: decode.isNumeric ? decode + offset : .invalid
        )
        var copy: CMSampleBuffer?
        guard
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: buffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &copy
            ) == noErr
        else { return nil }
        return copy
    }
}
