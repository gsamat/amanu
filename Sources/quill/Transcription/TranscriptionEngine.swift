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
    /// One call for the whole session against a single mixed-down file. The
    /// engine diarizes; the coordinator maps its labels back onto me/them by
    /// comparing each utterance's energy in the two source tracks.
    case mixed
}

/// A failure that retrying cannot fix: audio with no speech in it, a file that
/// isn't audio at all. The distinction matters because the queue is persistent
/// — a session with no transcript is picked up again at every launch, so a
/// permanent failure retried forever means uploading the same recording to a
/// paid API on every restart, which is what quill did until 2026.08.17.
protocol TranscriptionFailure: Error {
    var isPermanent: Bool { get }
}

/// A speech-to-text engine quill can run. Engines are prepared lazily (model
/// download + load) when the transcription queue has work and released when it
/// drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    /// Whether this engine wants each track separately or one mixed file.
    var input: TranscriptionInput { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
