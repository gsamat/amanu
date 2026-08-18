import AVFoundation
import Foundation

/// Puts amanu's me/them back on top of a diarizing engine's anonymous labels.
///
/// The engine only ever sees the mix, so all it can say is "A" and "B". But we
/// still have the two source tracks, and they answer the question directly:
/// whoever was loud on mic.caf while an utterance was spoken *is* the person
/// who spoke it.
///
/// The comparison is made per utterance and then settled per voice, and that
/// second half is the part worth explaining. A diarization label is a voice,
/// and a voice is a person; the track it arrives on is not. The far end comes
/// out of the speakers and back into the room mic, so some minority of one
/// person's utterances always reads as louder on the mic — across every real
/// session recorded on 18 August, every single voice appeared on both tracks,
/// the minority side running from 3% to 38% of that voice's utterances.
/// Deciding the side utterance by utterance therefore turned every person into
/// two speakers, and `2026.08.18-1024` shows the bill: the naming pass looked
/// at "me A" and at "them", identified each of them as Миша, at high
/// confidence, with a different quote apiece — and was right both times,
/// because they were both Миша. So the side is a majority verdict over the
/// whole meeting, and a voice keeps one name from beginning to end.
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

    /// Absolute RMS floor, about −46 dBFS: below this a bucket is room tone,
    /// fan noise or a hot preamp, not somebody talking.
    ///
    /// Normalizing each track against its own p90 is what makes two different
    /// gains comparable — and it's also why this floor has to exist. A track
    /// that carries no speech at all still gets normalized against its own
    /// noise, so its noise comes out at the same relative level as the other
    /// track's speech and can win the comparison outright. Measured on a real
    /// one-sided session (2026.08.17): the far end spoke on the system track
    /// at −22 dB mean, the mic held nothing but room noise at −62 dB, and
    /// every utterance was credited to "me". A floor in absolute terms is the
    /// only thing that separates the two cases, because after normalization
    /// they look identical.
    private static let speechFloor: Float = 0.005

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
        let sharedArchive = mic.standardizedFileURL == system.standardizedFileURL
        guard !segments.isEmpty,
              let micEnvelope = Envelope(url: mic, channel: sharedArchive ? 0 : nil),
              let systemEnvelope = Envelope(url: system, channel: sharedArchive ? 1 : nil)
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

        // Second pass: count where each voice landed, and put the whole voice
        // on the side that won. Nobody changes tracks halfway through a
        // meeting; the minority readings are the room mic hearing the far end
        // through the speakers.
        var majority: [String: (me: Int, them: Int)] = [:]
        for (segment, side) in zip(segments, sides) {
            guard let side, let label = segment.speaker else { continue }
            var tally = majority[label] ?? (0, 0)
            if side == .me { tally.me += 1 } else { tally.them += 1 }
            majority[label] = tally
        }
        let settled = majority.mapValues { $0.me > $0.them ? Side.me : Side.them }

        // Utterances the engine gave no label to have no voice to be settled
        // with, so they keep their own reading — or, where both tracks were
        // silent under speech, the side that spoke last. That is a dropout,
        // not a new speaker.
        var previous: Side = .them
        for i in sides.indices {
            if let label = segments[i].speaker, let side = settled[label] {
                sides[i] = side
                previous = side
            } else if let side = sides[i] {
                previous = side
            } else {
                sides[i] = previous
            }
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
        init?(url: URL, channel selectedChannel: Int? = nil) {
            guard
                FileManager.default.fileExists(atPath: url.path),
                let file = try? AVAudioFile(forReading: url),
                file.length > 0
            else { return nil }

            let format = file.processingFormat
            if let selectedChannel, selectedChannel >= Int(format.channelCount) { return nil }
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
                    let sample: Float
                    if let selectedChannel {
                        sample = channels[selectedChannel][frame]
                    } else {
                        var mixed: Float = 0
                        for channel in 0..<channelCount {
                            mixed += channels[channel][frame]
                        }
                        sample = mixed / Float(channelCount)
                    }
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
            // Buckets under the absolute floor contribute nothing: a track
            // with only room noise under this utterance must lose to one with
            // speech, however the two normalize.
            for i in first...last where buckets[i] >= SpeakerAttribution.speechFloor {
                sum += Double(buckets[i])
            }
            return sum / Double(last - first + 1) / Double(reference)
        }
    }
}
