import Foundation

/// Similar settings, deliberately different wire contracts. An unknown host
/// needs an explicit profile, so a reverse proxy never silently gets the wrong
/// fields or an audio upload meant for another service.
enum CompatibleTranscriptionProtocol: String, CaseIterable, Sendable {
    case automatic = "auto"
    case mlxAudio = "mlx-audio"
    case deepInfra = "deepinfra"
    case openRouter = "openrouter"
}

actor CompatibleTranscriptionEngine: TranscriptionEngine {
    enum Failure: TranscriptionFailure, CustomStringConvertible, Equatable {
        case configuration(String)
        case noAPIKey
        case unauthorized(Int)
        case insufficientCredits
        case rejected(Int)
        case unavailable(Int)
        case malformed
        case incomplete
        case invalidAudio
        case uploadTooLarge

        // Endpoint/account/contract problems must not consume the recording's
        // retry budget or trigger destructive "unreadable audio" handling.
        var isPermanent: Bool { false }
        var isEnvironmental: Bool {
            switch self {
            case .configuration, .noAPIKey, .unauthorized, .insufficientCredits,
                 .rejected, .malformed, .incomplete, .uploadTooLarge: return true
            case .unavailable, .invalidAudio: return false
            }
        }
        var description: String {
            switch self {
            case .configuration(let reason): return "compatible transcription configuration: \(reason)"
            case .noAPIKey: return "compatible transcription requires an API token for this provider"
            case .unauthorized(let status): return "compatible transcription token or access refused (HTTP \(status))"
            case .insufficientCredits: return "compatible transcription account has insufficient credits (HTTP 402)"
            case .rejected(let status): return "compatible transcription request rejected (HTTP \(status)); audio retained"
            case .unavailable(let status): return "compatible transcription service unavailable (HTTP \(status))"
            case .malformed: return "compatible transcription requires word timestamps and speaker labels; response incompatible"
            case .incomplete: return "compatible transcription response incomplete or generation limit reached; audio retained"
            case .invalidAudio: return "compatible transcription could not prepare the complete audio"
            case .uploadTooLarge: return "compatible transcription could not fit audio within the upload limit"
            }
        }
    }

    nonisolated let name = "compatible"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .mixed
    nonisolated let isLocalEndpoint: Bool
    nonisolated var runsRemotely: Bool { !isLocalEndpoint }
    nonisolated let supportsDiarization = true

    nonisolated let apiProtocol: CompatibleTranscriptionProtocol
    nonisolated let endpoint: URL
    private let apiKey: String?
    private let fields: [(String, String)]
    private let session: URLSession
    private let retry: CloudHTTP.RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let chunkDuration: TimeInterval
    private let maximumUploadBytes: Int
    static let maxTokens = 16_384

    // This is mlx-audio's SAA instruction. The native HTTP server forwards
    // `prompt`, not `task=saa`; JSON without verbose_json discards the words.
    static let speakerPrompt = "Transcribe this audio with punctuation and capitalization. Include all "
        + "spoken words and verbal fillers. Write numbers in their standard written form. "
        + "Put speaker tags <spk:0> <spk:1> <spk:2> <spk:3> <spk:4> <spk:5> <spk:6> "
        + "<spk:7> on the transcription."

    init(
        baseURL: String, model: String, apiKey: String? = nil,
        apiProtocol: CompatibleTranscriptionProtocol = .automatic,
        expectedLanguages: [String] = [], session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        chunkDuration: TimeInterval = 2_400, maximumUploadBytes: Int = 24_000_000
    ) throws {
        let resolved = try Self.resolve(baseURL: baseURL, protocol: apiProtocol, model: model)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.profile == .mlxAudio || key?.isEmpty == false else { throw Failure.noAPIKey }
        guard chunkDuration.isFinite, chunkDuration > 0, chunkDuration <= 2_400,
              maximumUploadBytes > 0, maximumUploadBytes <= 24_000_000
        else { throw Failure.configuration("invalid audio chunk limits") }
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiProtocol = resolved.profile
        endpoint = resolved.endpoint
        isLocalEndpoint = resolved.local
        self.apiKey = key?.isEmpty == false ? key : nil
        fields = Self.requestFields(profile: resolved.profile, model: self.model, expected: expectedLanguages)
        self.session = session
        self.retry = retry
        self.sleep = sleep
        self.chunkDuration = chunkDuration
        self.maximumUploadBytes = maximumUploadBytes
    }

    func prepare() async throws { try Task.checkCancellation() }
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        try await transcribe(audio, cacheDirectory: audio.deletingLastPathComponent())
    }

    func transcribe(_ audio: URL, cacheDirectory: URL) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-compatible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let prepared = try await CompatibleAudio.prepare(
            audio, in: scratch, aac: apiProtocol == .openRouter,
            chunkDuration: chunkDuration, maximumUploadBytes: maximumUploadBytes)
        var all: [TranscriptSegment] = []
        for (index, piece) in prepared.pieces.enumerated() {
            try Task.checkCancellation()
            let cache = ProviderCache.url(
                in: cacheDirectory, provider: "compatible",
                parts: ["contract-v1", endpoint.absoluteString, apiProtocol.rawValue, model,
                        CompatibleAudio.version, prepared.fingerprint,
                        "\(piece.firstFrame)", "\(piece.frames)",
                        apiProtocol == .openRouter ? "aac\(CompatibleAudio.aacBitRate)" : "wav16"]
                    + fields.map { "\($0.0)=\($0.1)" })
            let words: [Word]
            if let data = try? Data(contentsOf: cache),
               let cached = try? Self.words(from: data, profile: apiProtocol, duration: piece.duration) {
                words = cached
            } else {
                let data = try await upload(piece.url, in: scratch)
                words = try Self.words(from: data, profile: apiProtocol, duration: piece.duration)
                // Only a complete, validated response can be reused after a
                // later piece fails. The token is never part of a cache name.
                try data.write(to: cache, options: .atomic)
            }
            let prefix = prepared.pieces.count > 1 ? "p\(index + 1)-" : ""
            all += Self.segments(from: words, offset: piece.offset, speakerPrefix: prefix)
        }
        return all.sorted { $0.start < $1.start }
    }

    private func upload(_ file: URL, in scratch: URL) async throws -> Data {
        let boundary = "amanu.\(UUID().uuidString)"
        let body = scratch.appendingPathComponent("request.multipart")
        try CloudHTTP.writeMultipart(
            fields: fields, file: file, boundary: boundary, to: body,
            fileField: apiProtocol == .deepInfra ? "audio" : "file")
        defer { try? FileManager.default.removeItem(at: body) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.upload(for: request, fromFile: body)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // A dropped upload may have completed remotely. Do not pay
                // for a second inference automatically after transport loss.
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
            if http.statusCode == 402 { throw Failure.insufficientCredits }
            switch CloudHTTP.classify(status: http.statusCode) {
            case .success: return data
            case .unauthorized: throw Failure.unauthorized(http.statusCode)
            case .rejected: throw Failure.rejected(http.statusCode)
            case .retryable:
                guard attempt < retry.attempts else { throw Failure.unavailable(http.statusCode) }
                try await sleep(min(CloudHTTP.retryAfter(http)
                    ?? CloudHTTP.backoff(attempt: attempt, policy: retry), retry.maxDelay))
            }
        }
    }

    struct Resolved: Sendable {
        let profile: CompatibleTranscriptionProtocol
        let endpoint: URL
        let local: Bool
    }

    static func resolve(
        baseURL: String, protocol profile: CompatibleTranscriptionProtocol, model: String
    ) throws -> Resolved {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { throw Failure.configuration("base URL must be an HTTP(S) API base without credentials or query") }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || local else { throw Failure.configuration("remote endpoint requires HTTPS") }
        let chosen: CompatibleTranscriptionProtocol
        if profile != .automatic { chosen = profile }
        else if host == "api.deepinfra.com" { chosen = .deepInfra }
        else if host == "openrouter.ai" { chosen = .openRouter }
        else if local { chosen = .mlxAudio }
        else { throw Failure.configuration("choose an HTTP protocol for this host") }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.contains(where: { $0.isNewline || $0 == "\r" }) else {
            throw Failure.configuration("model is empty or invalid")
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.hasSuffix("audio/transcriptions"), !path.contains("/inference/") else {
            throw Failure.configuration("use an API base URL, not a transcription endpoint")
        }
        if chosen == .deepInfra, path.hasSuffix("openai") {
            throw Failure.configuration("DeepInfra native profile requires /v1, not /v1/openai")
        }
        var suffix = "audio/transcriptions"
        if chosen == .deepInfra {
            let parts = model.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else {
                throw Failure.configuration("invalid DeepInfra model path")
            }
            suffix = "inference/\(model)"
        }
        components.path = "/" + ([path, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = components.url else { throw Failure.configuration("invalid endpoint URL") }
        return Resolved(profile: chosen, endpoint: url, local: local)
    }

    static func requestFields(
        profile: CompatibleTranscriptionProtocol, model: String, expected: [String]
    ) -> [(String, String)] {
        var fields: [(String, String)]
        switch profile {
        case .mlxAudio, .automatic:
            fields = [("model", model), ("response_format", "verbose_json"),
                      ("word_timestamps", "true"), ("stream", "false"),
                      ("max_tokens", "\(maxTokens)"), ("prompt", speakerPrompt)]
        case .deepInfra:
            fields = [("chunk_level", "word"), ("diarize", "true"),
                      ("task", "transcribe"), ("temperature", "0")]
        case .openRouter:
            fields = [("model", model), ("response_format", "verbose_json"),
                      ("diarize", "true"), ("timestamp_granularities[]", "word"),
                      ("temperature", "0")]
        }
        if let language = MeetingLanguages.pin(for: expected) { fields.append(("language", language)) }
        return fields
    }

    struct Word: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let speaker: String
    }

    private struct Label: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int.self) { self.value = String(number) }
            else { self.value = try value.decode(String.self) }
        }
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let text: String?
            let word: String?
            let start: Double?
            let end: Double?
            let speaker: Label?
            let speaker_label: String?
            let type: String?
        }
        struct Status: Decodable { let status: String? }
        let text: String?
        let words: [Item]?
        let segments: [Item]?
        let generation_tokens: Int?
        let inference_status: Status?
        let finish_reason: String?
    }

    static func words(
        from data: Data, profile: CompatibleTranscriptionProtocol, duration: TimeInterval
    ) throws -> [Word] {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw Failure.malformed }
        if (response.generation_tokens ?? 0) >= maxTokens
            || ["length", "max_tokens"].contains(response.finish_reason ?? "") {
            throw Failure.incomplete
        }
        if let status = response.inference_status?.status?.lowercased(),
           ["failed", "error", "queued", "running", "pending"].contains(status) {
            throw Failure.incomplete
        }
        guard let items = profile == .mlxAudio ? response.segments : response.words else {
            throw Failure.malformed
        }
        // A provider can use either speaker IDs or display labels. Resolve
        // aliases across the whole response before assigning our own labels.
        var aliases: [String: String] = [:]
        for item in items {
            if let speaker = item.speaker?.value, let label = item.speaker_label {
                if let prior = aliases[label], prior != speaker { throw Failure.malformed }
                aliases[label] = speaker
            }
        }
        var result: [Word] = []
        for item in items {
            if item.type == "audio_event" { continue }
            guard item.type == nil || item.type == "word" else { throw Failure.malformed }
            let text = (item.word ?? item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let start = item.start, let end = item.end,
                  start.isFinite, end.isFinite, start >= 0, end > start, start < duration,
                  end <= duration + 0.25,
                  let rawSpeaker = item.speaker?.value
                    ?? item.speaker_label.map({ aliases[$0] ?? $0 }),
                  !rawSpeaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure.malformed }
            result.append(Word(start: min(start, duration), end: min(end, duration),
                               text: text, speaker: rawSpeaker))
        }
        if let text = response.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A valid-looking prefix of timed words is still incomplete.
            // Compare coverage, not global order: alignment can reorder words
            // across overlapping speakers. Include events here even though
            // they are intentionally omitted from the speech transcript.
            let timedText = items.compactMap { $0.word ?? $0.text }.joined(separator: " ")
            let all = coverage(timedText)
            let spoken = coverage(result.map(\.text).joined(separator: " "))
            let raw = coverage(text)
            // Some providers put event annotations in `text`, others omit
            // them. Every spoken token must occur, while event tokens may.
            guard Set(raw.keys).union(spoken.keys).allSatisfy({ token in
                (raw[token] ?? 0) >= (spoken[token] ?? 0)
                    && (raw[token] ?? 0) <= (all[token] ?? 0)
            }) else { throw Failure.incomplete }
        }
        return result.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
    }

    private static func coverage(_ text: String) -> [String: Int] {
        let speech = text.replacingOccurrences(of: #"<spk:\d+>"#, with: "", options: .regularExpression)
            .precomposedStringWithCanonicalMapping.lowercased().replacingOccurrences(of: "ё", with: "е")
        let words = speech.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace)
        return words.reduce(into: [:]) { $0[String($1), default: 0] += 1 }
    }

    static func segments(
        from words: [Word], offset: TimeInterval = 0, speakerPrefix: String = ""
    ) -> [TranscriptSegment] {
        var labels: [String: String] = [:]
        var output: [TranscriptSegment] = []
        var turn: [Word] = []
        func flush() {
            guard let first = turn.first, let last = turn.last else { return }
            let label = labels[first.speaker] ?? "A"
            output.append(TranscriptSegment(
                start: first.start + offset, end: max(last.end, turn.map(\.end).max() ?? last.end) + offset,
                text: turn.map(\.text).joined(separator: " "), speaker: speakerPrefix + label))
            turn.removeAll(keepingCapacity: true)
        }
        for word in words {
            if labels[word.speaker] == nil {
                let index = labels.count
                labels[word.speaker] = index < 26
                    ? String(UnicodeScalar(65 + index)!) : "S\(index + 1)"
            }
            if let previous = turn.last,
               previous.speaker != word.speaker || word.start - previous.end > 1
                || turn.count >= 60 || previous.text.last.map({ ".!?。！？".contains($0) }) == true {
                flush()
            }
            turn.append(word)
        }
        flush()
        return output
    }
}
