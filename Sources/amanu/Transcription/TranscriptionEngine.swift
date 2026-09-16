import Foundation

/// One timed span of recognized speech. Times are relative to whatever audio
/// the engine was handed — a single track for `.perTrack` engines, the mixed
/// session file for `.mixed` ones.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Diarization label from engines that identify speakers themselves
    /// (assemblyai's "A", "B", …). nil for per-track engines — there the track
    /// *is* the speaker, so the coordinator already knows.
    let speaker: String?

    init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// How the coordinator feeds a session's audio to an engine.
enum TranscriptionInput: Sendable {
    /// One call per track. mic → "me", system → "them"; free two-party
    /// diarization with no speaker model involved.
    case perTrack
    /// One call over aligned stereo: mic on channel 1, system on channel 2.
    /// The engine returns channel-qualified speaker labels, so no energy-based
    /// side attribution is needed.
    case multichannel
    /// One call for the whole session against a single mixed-down file. The
    /// engine diarizes; the coordinator maps its labels back onto me/them by
    /// comparing each utterance's energy in the two source tracks.
    case mixed

    var metadataName: String {
        switch self {
        case .perTrack: return "per-track"
        case .multichannel: return "multichannel"
        case .mixed: return "mixed"
        }
    }
}

/// AssemblyAI's multichannel diarization labels combine the one-based channel
/// and the voice within it (`1A`, `2B`). Amanu's stable vocabulary keeps those
/// two facts separate: channel 1 is `me`, channel 2 is `them`, and a suffix is
/// useful only while more than one voice survives on that side.
enum MultichannelSpeakerLabels {
    static func map(_ segments: [TranscriptSegment]) -> [Transcript.Segment] {
        segments.map { segment in
            Transcript.Segment(
                speaker: sideLabel(segment.speaker),
                start_ms: Int(segment.start * 1000),
                end_ms: Int(segment.end * 1000),
                text: segment.text)
        }
    }

    static func collapseSingleSides(
        _ segments: [Transcript.Segment]
    ) -> [Transcript.Segment] {
        let labels = ["me", "them"].reduce(into: [String: Set<String>]()) { out, side in
            out[side] = Set(segments.map(\.speaker).filter {
                $0 == side || $0.hasPrefix("\(side) ")
            })
        }
        return segments.map { segment in
            let side = ["me", "them"].first {
                segment.speaker == $0 || segment.speaker.hasPrefix("\($0) ")
            }
            guard let side, labels[side]?.count == 1 else { return segment }
            return Transcript.Segment(
                speaker: side,
                start_ms: segment.start_ms,
                end_ms: segment.end_ms,
                text: segment.text)
        }
    }

    private static func sideLabel(_ label: String?) -> String {
        guard let label, let channel = label.first else { return "speaker" }
        let side: String
        switch channel {
        case "1": side = "me"
        case "2": side = "them"
        default: return label
        }
        let suffix = label.dropFirst()
        return suffix.isEmpty ? side : "\(side) \(suffix)"
    }
}

/// Provider timestamps are untrusted data. AssemblyAI has returned an
/// utterance almost thirty seconds beyond a real 35-second file, and that text
/// otherwise becomes a plausible-looking part of the transcript. Every cloud
/// engine passes its segments through here for the same reason.
enum ProviderTimestamps {
    static func bounded(
        _ segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [TranscriptSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        return segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite else { return nil }
            let start = max(0, segment.start)
            let end = min(duration, segment.end)
            guard start < duration, end > start else { return nil }
            return TranscriptSegment(
                start: start,
                end: end,
                text: segment.text,
                speaker: segment.speaker)
        }
    }
}

/// A failure that retrying cannot fix: audio with no speech in it, a file that
/// isn't audio at all. The distinction matters because the queue is persistent
/// — a session with no transcript is picked up again at every launch, so a
/// permanent failure retried forever means uploading the same recording to a
/// paid API on every restart, which is what amanu did until 2026.08.17.
protocol TranscriptionFailure: Error {
    var isPermanent: Bool { get }
}

/// A speech-to-text engine amanu can run. Engines are prepared lazily (model
/// download + load) when the transcription queue has work and released when it
/// drains, so amanu never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    /// Whether this engine wants each track separately, aligned stereo, or one
    /// mixed file.
    var input: TranscriptionInput { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    /// Words this recording is likely to contain — today, the people the
    /// calendar says were invited. A recogniser told that "Galimov" is a word
    /// spells it that way instead of inventing something that sounds like it.
    ///
    /// It has a default because most engines have nowhere to put it: a local
    /// model takes no vocabulary, and an engine that ignores this is not
    /// broken. Engines are reused across sessions, so the coordinator calls
    /// this before every recording and an empty list means *forget the last
    /// one* — otherwise yesterday's attendees bias tomorrow's meeting.
    func expect(_ terms: [String]) async
    func release() async
}

extension TranscriptionEngine {
    func expect(_ terms: [String]) async {}
}

/// What of a meeting's context is worth handing to a speech recogniser, and
/// what must not be.
enum SpokenTerms {
    /// At most this many, which is the documented ceiling on WhisperAI's
    /// custom vocabulary and a sane bound everywhere else.
    static let limit = 100

    /// Calendar attendees, reduced to the ones that are names.
    ///
    /// An attendee with no display name in the event arrives as their email
    /// address — see `CalendarWatcher.convert`. An address is no use to a
    /// recogniser, since nobody says it out loud, and it is somebody's
    /// personal data going to a transcription vendor for nothing. So anything
    /// that looks like an address is dropped rather than cleaned up.
    static func from(attendees: [String]) -> [String] {
        var seen = Set<String>()
        return attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("@") }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }
}
