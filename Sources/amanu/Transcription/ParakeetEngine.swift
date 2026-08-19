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
/// v3 needs no language flag, but a language can be passed as a script hint:
/// it makes the decoder skip candidate tokens from the wrong script, which is
/// what keeps Russian from coming back transliterated into Latin (and vice
/// versa). The hint is v3-only — FluidAudio ignores it for v2.
///
/// The hint is a *script* filter and nothing finer — Russian and Ukrainian are
/// the same value to it, as are English and Polish. So it cannot be set from
/// the configured language alone: someone whose meetings are mostly Russian
/// still holds the occasional English one, and a Cyrillic filter over English
/// speech forbids the decoder every letter it needs. Where the expected
/// languages share an alphabet the filter is known up front; where they don't,
/// the audio decides — `sharedScript(of:)` and `dominantScript(of:)` below.
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
    /// `amanu doctor` so the cache check can't drift from what we download.
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
    /// The languages this recording may be in — one, two, or none at all.
    private let expected: [Language]
    private var manager: AsrManager?

    init(version: AsrModelVersion = ParakeetEngine.configuredVersion()) {
        self.version = version

        let configured = Config.transcriptionLanguage()
        let codes = MeetingLanguages.expected(primary: configured)
        if let configured, !configured.isEmpty, codes.isEmpty {
            let warning = "warning: parakeet doesn't know language \"\(configured)\" — "
                + "transcribing without a script hint\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        // v2 is English-only and doesn't fail on other languages — it forces
        // them through English phonetics and returns a plausible transcript.
        // Pairing it with a non-English language is that exact trap, so say so.
        if version == .v2, let configured, !configured.isEmpty, configured.lowercased() != "en" {
            let warning = "warning: parakeet v2 is English-only but language is "
                + "\"\(configured)\" — it will transcribe phonetic nonsense "
                + "rather than fail; set transcription.model to \"v3\"\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        // The script hint is a v3 decoder feature; FluidAudio ignores it
        // elsewhere, so don't record provenance implying it was applied.
        expected = version == .v3 ? codes.compactMap { Language(rawValue: $0) } : []

        let base = version == .v2
            ? "parakeet-tdt-0.6b-v2-coreml"
            : "parakeet-tdt-0.6b-v3-coreml"
        model = expected.isEmpty
            ? base
            : "\(base) (\(expected.map(\.rawValue).joined(separator: "+")))"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard manager != nil else { throw EngineError.notPrepared }

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

        // Where every expected language is written in the same alphabet, the
        // filter is known before a word is heard and one pass is the job.
        if let settled = Self.sharedScript(of: expected) {
            return transcript(from: try await run(audio, hint: settled))
        }

        // Otherwise the audio decides. The unfiltered pass is the question —
        // which alphabet did this come back in — and its answer chooses the
        // filter for the pass that is kept. Detection is a majority of the
        // letters rather than anything cleverer because the failure it guards
        // against is stray tokens from the wrong script, not a transcript
        // transliterated end to end.
        //
        // Two passes over the same file is the honest price: about forty
        // seconds an hour on Apple Silicon, paid once, after the meeting is
        // already over. Guessing instead costs a meeting.
        let probe = try await run(audio, hint: nil)
        guard let script = Self.dominantScript(of: probe.text),
              let hint = expected.first(where: { $0.script == script })
        else { return transcript(from: probe) }
        return transcript(from: try await run(audio, hint: hint))
    }

    private func run(_ audio: URL, hint: Language?) async throws -> ASRResult {
        guard let manager else { throw EngineError.notPrepared }
        var state = try TdtDecoderState()
        return try await manager.transcribe(audio, decoderState: &state, language: hint)
    }

    private func transcript(from result: ASRResult) -> [TranscriptSegment] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    /// The alphabet every expected language shares, or nil when they disagree
    /// — Russian and English always do, which is the ordinary case.
    static func sharedScript(of expected: [Language]) -> Language? {
        guard let first = expected.first else { return nil }
        return expected.allSatisfy { $0.script == first.script } ? first : nil
    }

    /// Which alphabet a transcript came back in, by counting its letters.
    ///
    /// nil for text with no letters at all — silence, or a track of nothing
    /// but punctuation — where there is nothing to conclude and the
    /// unfiltered pass is as good an answer as any.
    static func dominantScript(of text: String) -> Script? {
        var latin = 0, cyrillic = 0, greek = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Latin-1 carries × and ÷ among its letters; they are the only
            // two characters in these ranges that aren't ones.
            case 0x41...0x5A, 0x61...0x7A, 0x1E00...0x1EFF:
                latin += 1
            case 0xC0...0x24F where scalar.value != 0xD7 && scalar.value != 0xF7:
                latin += 1
            case 0x400...0x4FF:
                cyrillic += 1
            case 0x370...0x3FF, 0x1F00...0x1FFF:
                greek += 1
            default:
                continue
            }
        }
        // Counted in a fixed order and compared with `<`, so a tie resolves to
        // the last of the three rather than to whatever the run happens to
        // hash first. A tie means the text was half one alphabet and half
        // another, and there is no right answer to prefer.
        let counted = [(Script.latin, latin), (.cyrillic, cyrillic), (.greek, greek)]
        return counted.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
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
