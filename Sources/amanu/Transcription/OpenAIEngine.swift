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
/// Two things about the API leak into the code. Requests are capped at 25 MB,
/// which the mix passes at around 55 minutes, so a long meeting is cut into
/// pieces and the timings shifted back onto the session clock; the person who
/// recorded it never hears about any of this. And `chunking_strategy` is
/// required for anything over 30 seconds — the API refuses outright without
/// it, so it is always sent.
///
/// Every response is cached next to the audio as `transcript.openai*.json`,
/// so a retry after a crash re-renders from disk instead of re-uploading and
/// paying again.
actor OpenAITranscriptionEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case http(Int, String)
        case empty

        /// Only "there was no speech in this audio" is permanent; a silent
        /// recording will still be silent tomorrow. A missing key or an HTTP
        /// error is worth another go — see the note on the protocol.
        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no OpenAI API key — put one in \(Config.openAIKeyPath.path)"
                    + " (chmod 600) or set OPENAI_API_KEY"
            case .http(let code, let body):
                return "openai transcription failed: HTTP \(code) \(body.prefix(400))"
            case .empty:
                return "openai returned no speech"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// The API's own per-request ceiling. Not a guess: 25 MB is what the
    /// documentation states and what a larger file is refused with.
    static let defaultRequestLimit: Int64 = 25 * 1_048_576

    nonisolated let name = "openai"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .mixed

    private let apiKey: String
    private let language: String?
    /// A parameter rather than a constant so the sliced path can be exercised
    /// against real audio and the real API without a meeting long enough to
    /// pass 25 MB — an hour of it, every time anyone wanted to check.
    private let requestLimit: Int64

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init(requestLimit: Int64 = OpenAITranscriptionEngine.defaultRequestLimit) throws {
        guard let key = Config.openAIKey() else { throw EngineError.noAPIKey }
        apiKey = key
        language = Config.transcriptionLanguage()
        model = Config.openAITranscriptionModel()
        self.requestLimit = requestLimit
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let dir = audio.deletingLastPathComponent()
        let slices = try await sliced(audio)
        if slices.count > 1 {
            note("\(slices.count) pieces — the mix is over the API's limit")
        }

        var segments: [TranscriptSegment] = []
        for (index, slice) in slices.enumerated() {
            let cache = dir.appendingPathComponent(Self.cacheName(index, of: slices.count))
            let response: Response
            if let cached = try? Data(contentsOf: cache),
               let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
                note("reusing cached \(cache.lastPathComponent)")
                response = decoded
            } else {
                let raw = try await send(slice.url)
                response = try JSONDecoder().decode(Response.self, from: raw)
                try? raw.write(to: cache, options: .atomic)
            }
            segments += Self.segments(
                from: response,
                offset: slice.offset,
                // Labels are per request, so the "A" of one piece is not the
                // "A" of the next. Keeping them apart lets attribution settle
                // each voice on its own evidence instead of merging two
                // strangers who happened to be first in their piece.
                labelPrefix: slices.count > 1 ? "\(index + 1)" : nil
            )
        }
        Self.discardSlices(slices, of: audio)

        guard !segments.isEmpty else { throw EngineError.empty }
        return segments
    }

    // MARK: - slicing

    private func sliced(_ audio: URL) async throws -> [AudioSlicer.Slice] {
        let whole = [AudioSlicer.Slice(url: audio, offset: 0)]
        let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path)
        guard let bytes = attributes?[.size] as? Int64, bytes > requestLimit else {
            return whole
        }
        guard let length = AudioSlicer.sliceLength(
            bytes: bytes, duration: Self.duration(of: audio), limit: requestLimit
        ) else { return whole }
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

    /// One transcription request. The multipart body is assembled on disk and
    /// streamed from there: an hour of meeting is tens of megabytes, and the
    /// daemon has no business holding that on the heap while it uploads.
    private func send(_ audio: URL) async throws -> Data {
        let boundary = "amanu.\(UUID().uuidString)"
        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "diarized_json"),
            // Required by the diarizing model for anything over 30 seconds;
            // without it the API answers 400 rather than transcribing.
            ("chunking_strategy", "auto"),
        ]
        // The model detects the language itself; a configured one is still
        // passed, for the same reason it is passed to every other engine — a
        // told language beats a guessed one on a noisy first minute.
        if let language { fields.append(("language", language)) }

        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-openai-\(UUID().uuidString).multipart")
        try Self.writeMultipart(fields: fields, file: audio, boundary: boundary, to: body)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        // Uploading and transcribing an hour of audio outlasts the 60s default
        // several times over, and a timeout here costs the whole meeting.
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func writeMultipart(
        fields: [(String, String)],
        file: URL,
        boundary: String,
        to destination: URL
    ) throws {
        var header = ""
        for (name, value) in fields {
            header += "--\(boundary)\r\n"
            header += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            header += "\(value)\r\n"
        }
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"file\";"
            + " filename=\"\(file.lastPathComponent)\"\r\n"
        header += "Content-Type: audio/mp4\r\n\r\n"

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(header.utf8))

        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    // MARK: - shaping

    static func cacheName(_ index: Int, of count: Int) -> String {
        count > 1 ? "transcript.openai.\(index + 1).json" : "transcript.openai.json"
    }

    /// The response as amanu's segments: times moved onto the session clock,
    /// labels kept apart per piece. Pure, so the shifting and the labelling
    /// are testable without an API key.
    static func segments(
        from response: Response,
        offset: TimeInterval,
        labelPrefix: String?
    ) -> [TranscriptSegment] {
        if let segments = response.segments, !segments.isEmpty {
            return segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speaker = segment.speaker.map { label in
                    labelPrefix.map { "\($0)\(label)" } ?? label
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
    struct Response: Decodable, Sendable {
        struct Segment: Decodable, Sendable {
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
