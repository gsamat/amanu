import Foundation

/// Drops mic segments that are echoes of system playback. When a meeting
/// plays through the speakers and the mic is recording raw (no voice
/// processing), the mic hears the speakers — everything the far end says is
/// transcribed twice, once as "them" from the system tap and again as "me"
/// from the mic, often louder than the user's own voice.
///
/// A me segment whose words are almost all contained, in order, in the them
/// speech it overlaps is the speakers heard twice, not the user talking over
/// them. Matching is word-level and fuzzy because the two tracks transcribe
/// the same audio slightly differently (the acoustic copy is degraded), and
/// them windows are padded because the room path lags the system tap and the
/// segmenter draws boundaries loosely. With multichannel diarization, a mic
/// speaker overwhelmingly proven to be that acoustic copy also loses its
/// short overlapping ASR near-misses; non-overlapping speech is still kept.
///
/// `mic_voice_processing` prevents the echo at capture; this pass guards
/// sessions recorded raw (or where the voice unit fell back).
enum EchoFilter {
    /// How far (ms) beyond a them segment's span a me segment still counts as
    /// overlapping it.
    private static let overlapPadMs = 400
    /// Word containment at or above this marks a me segment as echo.
    private static let containmentThreshold = 0.7
    /// A channel-qualified mic speaker with this much evidence can be treated
    /// as the far end's acoustic copy. Unsuffixed `me` is never classified:
    /// per-track engines use it for every local voice, including the user.
    private static let echoSpeakerMinimumSegments = 20
    private static let echoSpeakerMatchRatio = 0.8

    /// Returns `segments` without the me segments judged to be echo.
    /// Preserves order; no-op when a track is missing.
    static func dropEchoes(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        let them = segments.filter { isSide($0.speaker, "them") }
        guard !them.isEmpty else { return segments }

        let mic: [(index: Int, speaker: String, overlaps: Bool, directEcho: Bool)] =
            segments.enumerated().compactMap { index, segment in
            guard isSide(segment.speaker, "me") else { return nil }
            let overlapping = overlappingThem(for: segment, in: them)
            return (
                index: index,
                speaker: segment.speaker,
                overlaps: !overlapping.isEmpty,
                directEcho: isEcho(segment, of: overlapping)
            )
        }
        let bySpeaker = Dictionary(grouping: mic.filter { $0.speaker != "me" }) {
            $0.speaker
        }
        let echoSpeakers: Set<String> = Set(bySpeaker.compactMap { speaker, evidence -> String? in
            guard evidence.count >= echoSpeakerMinimumSegments else { return nil }
            let matches = evidence.count(where: \.directEcho)
            return Double(matches) / Double(evidence.count) >= echoSpeakerMatchRatio
                ? speaker
                : nil
        })
        let dropped = Set(mic.compactMap { evidence in
            evidence.directEcho || (evidence.overlaps && echoSpeakers.contains(evidence.speaker))
                ? evidence.index
                : nil
        })
        return segments.enumerated().compactMap { index, segment in
            dropped.contains(index) ? nil : segment
        }
    }

    private static func isSide(_ speaker: String, _ side: String) -> Bool {
        speaker == side || speaker.hasPrefix("\(side) ")
    }

    private static func overlappingThem(
        for me: Transcript.Segment,
        in them: [Transcript.Segment]
    ) -> [Transcript.Segment] {
        them.filter {
            min(me.end_ms, $0.end_ms + overlapPadMs) > max(me.start_ms, $0.start_ms - overlapPadMs)
        }
    }

    private static func isEcho(
        _ me: Transcript.Segment,
        of overlapping: [Transcript.Segment]
    ) -> Bool {
        guard !overlapping.isEmpty else { return false }

        let meWords = words(me.text)
        // Nothing to compare — a punctuation-only segment, or a script this
        // tokenizer mishandles. Keep it: this filter's failure mode is
        // deleting speech the user actually said, so it has to fail toward
        // keeping rather than toward dropping.
        guard !meWords.isEmpty else { return false }
        let themWords = overlapping.flatMap { words($0.text) }

        let contained = Double(subsequenceLength(of: meWords, in: themWords))
            / Double(meWords.count)
        // One- and two-word segments ("um", "yeah") match too easily — only an
        // exact hit drops them, so genuine backchannels survive.
        return meWords.count <= 2
            ? contained == 1.0
            : contained >= containmentThreshold
    }

    /// Lowercased words with punctuation stripped (apostrophes kept), so
    /// "Right?!" and "right" compare equal.
    ///
    /// Deliberately not restricted to ASCII: `isLetter` already excludes
    /// punctuation, and adding an `isASCII` conjunct silently reduces every
    /// non-Latin script to zero words — which made this filter delete the
    /// user's entire side of any Russian, Greek, or Ukrainian meeting.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " }
            .split(separator: " ")
            .map(String.init)
    }

    /// Longest common subsequence length: how many of `a`'s words appear in
    /// `b` in the same order, gaps allowed. Segments are sentence-sized, so
    /// the quadratic table is nothing.
    private static func subsequenceLength(of a: [String], in b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = prev
        for i in 1...a.count {
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1] + 1
                    : max(prev[j], curr[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
