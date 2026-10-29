import AVFoundation
import Foundation

/// OpenAI's diarizing transcription, over the mixed-down session audio.
///
/// The model is `gpt-4o-transcribe-diarize`, and it is the only one of
/// OpenAI's transcription models amanu can use: the others return running text
/// with no timings at all, and a transcript with no clock can be neither
/// aligned with the recording nor attributed to a speaker. This one returns
/// segments with start, end and a speaker label — the same shape AssemblyAI
/// returns, which is why both are `.mixed` engines and share everything
/// downstream.
///
/// Three things about the API leak into the code. Requests are capped at 25 MB
/// and 1400 seconds, and a piece takes far longer to answer the longer it is,
/// so a meeting is cut into five-minute pieces, sent all at once, and the
/// timings shifted back onto the session clock; the person who recorded it
/// never hears about any of this. Speaker labels are per request, so the first
/// piece goes ahead of the rest and a few seconds of each voice it heard go
/// with every other as `known_speaker_references`. And `chunking_strategy` is
/// required for anything over 30 seconds — the API refuses outright without
/// it, so it is always sent.
///
/// Every response is cached next to the audio (see `ProviderCache`), so a
/// retry after a crash re-renders from disk instead of re-uploading and
/// paying again.
actor OpenAITranscriptionEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case empty

        /// Only "there was no speech in this audio" is permanent; a silent
        /// recording will still be silent tomorrow. HTTP answers are
        /// classified by `CloudHTTP`.
        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var isEnvironmental: Bool {
            if case .noAPIKey = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no OpenAI API key — put one in \(Config.openAIKeyPath.path)"
                    + " (chmod 600) or set OPENAI_API_KEY"
            case .empty:
                return "openai returned no speech"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// The API's own per-request ceiling. Not a guess: 25 MB is what the
    /// documentation states and what a larger file is refused with.
    static let defaultRequestLimit: Int64 = 25 * 1_048_576
    /// The longest piece. The API refuses anything over 1400 seconds, but the
    /// reason for five minutes is speed: measured on 29 October 2026, twenty
    /// minutes took 7–9 minutes as one request and 2.2 minutes as four
    /// five-minute ones sent together; an hour as twelve took the same. One-
    /// and two-minute pieces were faster still, by a minute an hour, and give
    /// the diarizer less of each voice to go on.
    static let defaultDurationLimit: TimeInterval = 300
    /// Pieces in flight at once. Sixty were measured without a refusal; this
    /// covers a three-hour meeting at five minutes a piece in one round.
    static let parallelPieces = 36
    /// The API's maximum number of known speakers per request.
    static let maxKnownVoices = 4
    /// Tries per piece for a stream that stops before it is finished, which
    /// one in thirty did in the same measurement.
    static let streamAttempts = 3

    nonisolated let name = "openai"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .mixed

    private let apiKey: String
    /// The languages this meeting may be in. Consulted for one decision only —
    /// whether a language can be named at all — because the API has no way to
    /// narrow detection to a set the way assemblyai's `expected_languages`
    /// does. See `languageField(for:)`.
    private let expected: [String]
    /// Parameters rather than constants so the sliced path can be exercised
    /// against real audio and the real API without a meeting long enough to
    /// pass either limit — an hour of it, every time anyone wanted to check.
    private let requestLimit: Int64
    private let durationLimit: TimeInterval
    private let http: CloudHTTP

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init(
        requestLimit: Int64 = OpenAITranscriptionEngine.defaultRequestLimit,
        durationLimit: TimeInterval = OpenAITranscriptionEngine.defaultDurationLimit,
        apiKey: String? = nil,
        session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let key = apiKey ?? Config.openAIKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        model = Config.openAITranscriptionModel()
        self.requestLimit = requestLimit
        self.durationLimit = durationLimit
        http = CloudHTTP(service: .openAI, session: session, retry: retry, sleep: sleep)
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let dir = audio.deletingLastPathComponent()
        let slices = try await sliced(audio)
        if slices.count > 1 {
            note("\(slices.count) pieces — the mix is over the API's limit")
        }

        // The first piece goes ahead: every voice it hears is one the rest
        // are told about. Labels are per request otherwise, so the "A" of one
        // piece is not the "A" of the next, and each piece's are prefixed.
        let count = slices.count
        let prefix: @Sendable (Int) -> String? = { count > 1 ? "\($0 + 1)" : nil }
        let first = try await response(
            for: slices[0], cache: cacheURL(in: dir, audio: audio, piece: 0, of: count), voices: [])
        let voices = prefix(0).map { Self.voices(from: first, in: slices[0].url, labelPrefix: $0) } ?? []
        let known = Set(voices.map(\.name))
        var pieces = [0: Self.segments(from: first, offset: 0, labelPrefix: prefix(0))]

        try await withThrowingTaskGroup(of: (Int, [TranscriptSegment]).self) { group in
            var next = 1
            func start() {
                guard next < count else { return }
                let (index, slice) = (next, slices[next])
                let cache = cacheURL(in: dir, audio: audio, piece: index, of: count, voices: voices)
                next += 1
                group.addTask {
                    let response = try await self.response(for: slice, cache: cache, voices: voices)
                    return (index, Self.segments(
                        from: response, offset: slice.offset,
                        labelPrefix: prefix(index), known: known))
                }
            }
            for _ in 0..<Self.parallelPieces { start() }
            while let (index, segments) = try await group.next() {
                pieces[index] = segments
                start()
            }
        }
        let segments = pieces.keys.sorted().flatMap { pieces[$0]! }
        Self.discardSlices(slices, of: audio)

        guard !segments.isEmpty else { throw EngineError.empty }
        return segments
    }

    /// One piece's answer, from the cache when an earlier attempt already
    /// paid for it.
    private func response(
        for slice: AudioSlicer.Slice, cache: URL, voices: [Voice]
    ) async throws -> Response {
        if let cached = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
            note("reusing cached \(cache.lastPathComponent)")
            return decoded
        }
        var ending = ""
        for attempt in 1...Self.streamAttempts {
            let raw = try await send(slice.url, voices: voices)
            if let decoded = Self.parse(raw) {
                try? JSONEncoder().encode(decoded).write(to: cache, options: .atomic)
                return decoded
            }
            // The end, not the start: a stream cut short starts like a whole one.
            ending = String(decoding: raw.suffix(400), as: UTF8.self)
            note("\(slice.url.lastPathComponent) stopped before it was finished"
                + " (try \(attempt) of \(Self.streamAttempts)); it ended: \(ending)")
        }
        throw CloudHTTP.Failure.malformed(
            service: CloudService.openAI.rawValue, what: "transcription", body: ending)
    }

    /// An answer sent with `stream=true`: one `transcript.text.segment` event
    /// per utterance, pings between them, `transcript.text.done`, `[DONE]`.
    /// Nil for a stream that reports an error or ends before it says it is
    /// done — a piece cut short must not be cached as if it were the whole.
    static func parse(_ raw: Data) -> Response? {
        struct Event: Decodable {
            let type: String
            let text: String?
            let speaker: String?
            let start: TimeInterval?
            let end: TimeInterval?
        }
        var segments: [Response.Segment] = []
        for line in String(decoding: raw, as: UTF8.self).split(whereSeparator: \.isNewline)
        where line.hasPrefix("data: ") {
            // A line that cannot be read is an utterance lost, so the whole
            // stream is asked for again rather than cached without it.
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.dropFirst(6).utf8))
            else { return nil }
            switch event.type {
            case "transcript.text.segment":
                guard let start = event.start, let end = event.end else { return nil }
                segments.append(.init(
                    start: start, end: end, text: event.text ?? "", speaker: event.speaker))
            case "transcript.text.done":
                return Response(text: event.text, duration: nil, segments: segments)
            case "error":
                return nil
            default:
                continue
            }
        }
        return nil
    }

    // MARK: - voices

    /// A speaker the other pieces are told about: the first piece's name for
    /// them, and a few seconds of their voice as a `data:` URL.
    struct Voice: Sendable {
        let name: String
        let sample: String
    }

    /// Where in the first piece the voices worth naming can be heard: the four
    /// who talked longest — the API's maximum — each by its longest utterance,
    /// trimmed to the eight seconds the API's two-to-ten allows. A voice with
    /// nothing two seconds long is a cough or crosstalk, and is left out.
    static func voiceSamples(
        in segments: [Response.Segment], labelPrefix: String
    ) -> [(name: String, start: TimeInterval, length: TimeInterval)] {
        let bySpeaker = Dictionary(grouping: segments.filter { $0.end > $0.start }) { $0.speaker ?? "" }
            .filter { !$0.key.isEmpty }
        let talked = bySpeaker.mapValues { $0.reduce(0) { $0 + $1.end - $1.start } }
        return talked.keys.sorted { (talked[$0]!, $1) > (talked[$1]!, $0) }
            .compactMap { speaker in
                let longest = bySpeaker[speaker]!.max { $0.end - $0.start < $1.end - $1.start }!
                guard longest.end - longest.start >= 2 else { return nil }
                return (labelPrefix + speaker, longest.start, min(8, longest.end - longest.start))
            }
            .prefix(maxKnownVoices).map { $0 }
    }

    /// The samples, cut from the first piece. One that cannot be cut is left
    /// out; the rest still help.
    static func voices(from response: Response, in piece: URL, labelPrefix: String) -> [Voice] {
        voiceSamples(in: response.segments ?? [], labelPrefix: labelPrefix).compactMap {
            guard let wav = try? AudioClip.wav(from: piece, start: $0.start, length: $0.length)
            else { return nil }
            return Voice(name: $0.name, sample: "data:audio/wav;base64," + wav.base64EncodedString())
        }
    }

    // MARK: - slicing

    private func sliced(_ audio: URL) async throws -> [AudioSlicer.Slice] {
        let whole = [AudioSlicer.Slice(url: audio, offset: 0)]
        let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path)
        guard let bytes = attributes?[.size] as? Int64,
              let length = AudioSlicer.sliceLength(
                bytes: bytes, duration: Self.duration(of: audio), limit: requestLimit,
                maxDuration: durationLimit)
        else { return whole }
        return try await AudioSlicer.slice(audio, every: length, into: Self.sliceDirectory(audio))
    }

    private static func sliceDirectory(_ audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent("openai-slices")
    }

    /// The pieces are derived and disposable; the mix they came from is not.
    private static func discardSlices(_ slices: [AudioSlicer.Slice], of audio: URL) {
        guard slices.contains(where: { $0.url != audio }) else { return }
        try? FileManager.default.removeItem(at: sliceDirectory(audio))
    }

    private static func duration(of audio: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: audio),
              file.processingFormat.sampleRate > 0
        else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - API

    /// One transcription request, streamed from a multipart body on disk.
    private func send(_ audio: URL, voices: [Voice]) async throws -> Data {
        try await http.sendMultipart(
            to: Self.endpoint, fields: Self.fields(model: model, expected: expected, voices: voices),
            file: audio, key: apiKey,
            what: "transcription", timeout: 300, retryTransportErrors: true)
    }

    /// The request's form fields. Pure, so what is sent is testable.
    static func fields(model: String, expected: [String], voices: [Voice]) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "diarized_json"),
            // Required by the diarizing model for anything over 30 seconds;
            // without it the API answers 400 rather than transcribing.
            ("chunking_strategy", "auto"),
            // Something arrives every few seconds while the server works, so
            // five quiet minutes do mean a dead connection. Unstreamed, an
            // answer can take minutes of silence, and on 28 October 2026 one
            // from amanu never came while curl's copy of the request was
            // answered.
            ("stream", "true"),
        ]
        if let language = languageField(for: expected) {
            fields.append(("language", language))
        }
        // Two arrays matched by position.
        fields += voices.map { ("known_speaker_names[]", $0.name) }
        fields += voices.map { ("known_speaker_references[]", $0.sample) }
        return fields
    }

    /// The `language` field for a request, or nil to let the model detect.
    /// The API has nothing beside it — no `expected_languages`, no candidate
    /// list — to express an expectation instead, so it follows the rule every
    /// such engine follows: `MeetingLanguages.pin(for:)`.
    static func languageField(for expected: [String]) -> String? {
        MeetingLanguages.pin(for: expected)
    }

    // MARK: - shaping

    /// Where one piece's response is cached: named for the model, the
    /// language sent, the limits that decided the cuts, which piece of how
    /// many it is, and the voices it was told about — the samples too, since
    /// a first piece heard again may give the same names to other people.
    func cacheURL(
        in dir: URL, audio: URL, piece index: Int, of count: Int, voices: [Voice] = []
    ) -> URL {
        ProviderCache.url(
            in: dir, provider: .openAI,
            parts: [
                audio.lastPathComponent, model, Self.languageField(for: expected) ?? "detect",
                "\(requestLimit)", "\(durationLimit)", "\(count)",
            ] + voices.flatMap { [$0.name, $0.sample] },
            suffix: count > 1 ? "\(index + 1)" : nil)
    }

    /// The response as amanu's segments: times moved onto the session clock,
    /// labels kept apart per piece. Pure, so the shifting and the labelling
    /// are testable without an API key.
    static func segments(
        from response: Response,
        offset: TimeInterval,
        labelPrefix: String?,
        known: Set<String> = []
    ) -> [TranscriptSegment] {
        if let segments = response.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                // A voice the request was told about comes back under the
                // first piece's own name for it.
                let speaker = segment.speaker.map { label in
                    known.contains(label) ? label : labelPrefix.map { "\($0)\(label)" } ?? label
                }
                return TranscriptSegment(
                    start: segment.start + offset,
                    end: max(segment.start, segment.end) + offset,
                    text: text,
                    speaker: speaker
                )
            }
        }
        // No segments at all: a piece with speech but nothing the diarizer
        // would split. Keeping the flat text beats dropping the minutes.
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            start: offset,
            end: offset + (response.duration ?? 0),
            text: text
        )]
    }

    /// The slice of the API response amanu uses. Everything else it returns —
    /// usage, logprobs, the task name — is none of our business.
    struct Response: Codable, Sendable {
        struct Segment: Codable, Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: String?
        }

        let text: String?
        let duration: TimeInterval?
        let segments: [Segment]?
    }

    /// Progress goes to stderr; the coordinator owns transcribe.log and only
    /// hears about outcomes.
    private nonisolated func note(_ message: String) {
        FileHandle.standardError.write(Data("openai: \(message)\n".utf8))
    }
}
