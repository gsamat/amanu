import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B via FluidAudio's Core ML port. Models download once into
/// FluidAudio's managed cache (~600 MB); after that, transcription runs
/// entirely on-device at roughly 20 seconds per hour of audio on Apple
/// Silicon.
///
/// Two model versions, selected with `transcription.model`: v3 is multilingual
/// (25 European languages, Russian included) and detects the spoken language
/// itself; v2 is English-only with marginally higher recall on English.
///
/// v3 needs no language flag, but a configured language is passed as a script
/// hint: it makes the decoder skip candidate tokens from the wrong script,
/// which is what keeps Russian from coming back transliterated into Latin (and
/// vice versa). The hint is v3-only — FluidAudio ignores it for v2.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    /// The configured model version, warning and falling back rather than
    /// silently transcribing with one the user didn't ask for. Shared with
    /// `quill doctor` so the cache check can't drift from what we download.
    static func configuredVersion() -> AsrModelVersion {
        switch Config.transcriptionModel() {
        case "v3": return .v3
        case "v2": return .v2
        case let other:
            FileHandle.standardError.write(Data(
                "warning: unknown parakeet model \"\(other)\" — using v3\n".utf8
            ))
            return .v3
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .perTrack

    private let version: AsrModelVersion
    private let language: Language?
    private var manager: AsrManager?

    init(version: AsrModelVersion = ParakeetEngine.configuredVersion()) {
        self.version = version

        let configured = Config.transcriptionLanguage()
        let parsed = configured.flatMap { Language(rawValue: $0) }
        if let configured, parsed == nil {
            let warning = "warning: parakeet doesn't know language \"\(configured)\" — "
                + "transcribing without a script hint\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        // v2 is English-only and doesn't fail on other languages — it forces
        // them through English phonetics and returns a plausible transcript.
        // Pairing it with a non-English language is that exact trap, so say so.
        if version == .v2, let parsed, parsed != .english {
            let warning = "warning: parakeet v2 is English-only but language is "
                + "\"\(parsed.rawValue)\" — it will transcribe phonetic nonsense "
                + "rather than fail; set transcription.model to \"v3\"\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        // The script hint is a v3 decoder feature; FluidAudio ignores it
        // elsewhere, so don't record provenance implying it was applied.
        language = version == .v3 ? parsed : nil

        let base = version == .v2
            ? "parakeet-tdt-0.6b-v2-coreml"
            : "parakeet-tdt-0.6b-v3-coreml"
        model = language.map { "\(base) (\($0.rawValue))" } ?? base
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state, language: language)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (parakeet emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
