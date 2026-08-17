import AVFoundation
import Foundation

/// Puts quill's me/them back on top of a diarizing engine's anonymous labels.
///
/// The engine only ever sees the mix, so all it can say is "A" and "B". But we
/// still have the two source tracks, and they answer the question directly:
/// whoever was loud on mic.caf while an utterance was spoken *is* the person
/// who spoke it. So the side is decided per utterance, not per label — a model
/// that merges two similar voices into one label still comes out correctly
/// split, because the tracks disagree even when the diarizer doesn't.
///
/// The labels still earn their keep on the far side: three people sharing one
/// room mic are all "them", and only diarization can tell them apart. So the
/// name is side + label, with the label dropped when a side has only one.
///
/// Levels aren't comparable raw — the mic runs at whatever gain the device
/// picked, the system tap at playback level — so each envelope is normalized
/// against its own loud-speech level before the comparison.
enum SpeakerAttribution {
    /// Resolution of the envelope in seconds. Speech energy at 100 ms is
    /// stable enough to attribute and cheap enough to compute for a long
    /// meeting in one pass.
    private static let bucket: TimeInterval = 0.1

    private enum Side {
        case me, them
        var name: String { self == .me ? "me" : "them" }
    }

    /// Speaker names for `segments`, in order. Returns nil when the source
    /// tracks can't settle it — the caller should then keep the engine's raw
    /// labels rather than inventing an answer.
    ///
    /// `micOffset` / `systemOffset` are the tracks' start offsets on the mixed
    /// clock: a segment at mixed time T sits at T − offset inside its track.
    static func resolve(
        segments: [TranscriptSegment],
        mic: URL,
        micOffset: TimeInterval,
        system: URL,
        systemOffset: TimeInterval
    ) -> [String]? {
        guard !segments.isEmpty,
              let micEnvelope = Envelope(url: mic),
              let systemEnvelope = Envelope(url: system)
        else { return nil }

        // First pass: whichever track is louder over the utterance spoke it.
        // A stretch where both read as silence stays undecided for now.
        var sides: [Side?] = segments.map { segment in
            guard segment.end > segment.start else { return nil }
            let me = micEnvelope.level(
                from: segment.start - micOffset, to: segment.end - micOffset)
            let them = systemEnvelope.level(
                from: segment.start - systemOffset, to: segment.end - systemOffset)
            guard me > 0 || them > 0 else { return nil }
            return me > them ? .me : .them
        }
        guard sides.contains(where: { $0 != nil }) else { return nil }

        // Second pass: fill the undecided ones from the side their diarization
        // label usually lands on, falling back to whoever spoke last. Both
        // tracks reading silent under speech means a dropout, not a new
        // speaker.
        var majority: [String: (me: Int, them: Int)] = [:]
        for (segment, side) in zip(segments, sides) {
            guard let side, let label = segment.speaker else { continue }
            var tally = majority[label] ?? (0, 0)
            if side == .me { tally.me += 1 } else { tally.them += 1 }
            majority[label] = tally
        }
        var previous: Side = .them
        for i in sides.indices {
            if let side = sides[i] {
                previous = side
                continue
            }
            let tally = segments[i].speaker.flatMap { majority[$0] }
            sides[i] = tally.map { $0.me > $0.them ? .me : .them } ?? previous
        }

        // Name each side. The label only survives where a side actually holds
        // more than one person — otherwise "them" beats "them A".
        var labelsPerSide: [String: Set<String>] = [:]
        for (segment, side) in zip(segments, sides) {
            guard let side, let label = segment.speaker else { continue }
            labelsPerSide[side.name, default: []].insert(label)
        }
        // Sorted so the suffixes are stable across reruns rather than
        // whatever order the set iterates in.
        let suffixes = labelsPerSide.mapValues { labels -> [String: String] in
            let sorted = labels.sorted()
            guard sorted.count > 1 else { return [:] }
            return Dictionary(uniqueKeysWithValues: sorted.enumerated().map {
                ($0.element, Self.suffix($0.offset))
            })
        }

        return zip(segments, sides).map { segment, side in
            let name = (side ?? .them).name
            guard let label = segment.speaker,
                  let suffix = suffixes[name]?[label]
            else { return name }
            return "\(name) \(suffix)"
        }
    }

    private static func suffix(_ index: Int) -> String {
        // A, B, … Z, then fall back to numbers rather than wrapping.
        index < 26
            ? String(UnicodeScalar(UInt8(65 + index)))
            : String(index + 1)
    }

    /// A track's loudness over time, in fixed-width buckets, normalized so it
    /// can be compared against another track recorded at a different gain.
    private struct Envelope {
        private let buckets: [Float]
        private let reference: Float

        /// Read the file once, streaming, and reduce it to per-bucket RMS.
        /// nil if the file is missing, empty, or entirely silent.
        init?(url: URL) {
            guard
                FileManager.default.fileExists(atPath: url.path),
                let file = try? AVAudioFile(forReading: url),
                file.length > 0
            else { return nil }

            let format = file.processingFormat
            let framesPerBucket = max(1, Int(format.sampleRate * SpeakerAttribution.bucket))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBucket * 10)
            ) else { return nil }

            var out: [Float] = []
            var carrySquares: Float = 0
            var carryFrames = 0

            while true {
                buffer.frameLength = 0
                guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                guard let channels = buffer.floatChannelData else { break }
                let channelCount = Int(format.channelCount)
                let frames = Int(buffer.frameLength)

                for frame in 0..<frames {
                    var sample: Float = 0
                    for channel in 0..<channelCount {
                        sample += channels[channel][frame]
                    }
                    sample /= Float(channelCount)
                    carrySquares += sample * sample
                    carryFrames += 1
                    if carryFrames == framesPerBucket {
                        out.append((carrySquares / Float(framesPerBucket)).squareRoot())
                        carrySquares = 0
                        carryFrames = 0
                    }
                }
            }
            if carryFrames > 0 {
                out.append((carrySquares / Float(carryFrames)).squareRoot())
            }
            guard !out.isEmpty else { return nil }

            // Normalize against the track's own loud-speech level, not its
            // peak: a single door slam shouldn't rescale a whole meeting.
            let sorted = out.sorted()
            let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            guard p90 > 0 else { return nil }

            buckets = out
            reference = p90
        }

        /// Mean normalized loudness over a time range, in seconds. Ranges that
        /// fall outside the track (it started later, or ended earlier) read as
        /// silence, which is exactly right — nothing of this speaker is there.
        func level(from start: TimeInterval, to end: TimeInterval) -> Double {
            let first = max(0, Int(start / SpeakerAttribution.bucket))
            let last = min(buckets.count - 1, Int(end / SpeakerAttribution.bucket))
            guard first <= last, first < buckets.count else { return 0 }
            var sum: Double = 0
            for i in first...last { sum += Double(buckets[i]) }
            return sum / Double(last - first + 1) / Double(reference)
        }
    }
}
