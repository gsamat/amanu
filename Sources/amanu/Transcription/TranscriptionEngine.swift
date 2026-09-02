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
    func release() async
}
