import AVFoundation
import Foundation

/// Mixes a session's tracks down to one file on the shared clock — each track
/// laid in at its own start offset, so the mix has the same timeline the
/// two-track transcript would.
///
/// This exists for diarizing engines: they need a single stream with everybody
/// on it, and there's no way to diarize across two files. The output is m4a
/// (AAC in MP4) rather than CAF because it goes to an API — m4a is what
/// everything accepts. Unlike the source tracks, the mix isn't crash-safe, but
/// it doesn't need to be: it's derived, and regenerating it costs seconds.
enum AudioMixer {
    struct Track {
        let url: URL
        let offset: TimeInterval
    }

    enum MixError: Error, CustomStringConvertible {
        case noUsableTracks
        case compositionFailed
        case exportUnavailable

        var description: String {
            switch self {
            case .noUsableTracks: return "no readable audio tracks to mix"
            case .compositionFailed: return "couldn't build the mix composition"
            case .exportUnavailable: return "no m4a export session available"
            }
        }
    }

    /// Write `tracks` mixed down into `output`, replacing whatever was there.
    /// A track that's missing, empty, or unreadable is skipped — one dead
    /// track shouldn't cost the other one its transcript.
    static func mix(_ tracks: [Track], to output: URL) async throws {
        let composition = AVMutableComposition()
        var used = 0

        for track in tracks {
            guard FileManager.default.fileExists(atPath: track.url.path) else { continue }
            let asset = AVURLAsset(url: track.url)
            guard
                let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                duration.seconds > 0,
                let destination = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else { continue }

            do {
                try destination.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: source,
                    at: CMTime(seconds: track.offset, preferredTimescale: 1000)
                )
                used += 1
            } catch {
                // Truncated tail, unreadable packets — drop the track rather
                // than the whole mix, same as the per-track path does.
                composition.removeTrack(destination)
                FileHandle.standardError.write(Data(
                    "warning: skipping \(track.url.lastPathComponent) in mix: \(error)\n".utf8
                ))
            }
        }
        guard used > 0 else { throw MixError.noUsableTracks }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw MixError.exportUnavailable }

        // Export refuses to overwrite, and a leftover from a failed run would
        // otherwise wedge every retry.
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .m4a)
    }
}
