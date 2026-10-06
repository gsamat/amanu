import CryptoKit
import Foundation

/// Cloud transcription services and their shared credential, authorization,
/// and reachability policies.
enum CloudService: String, CaseIterable, Sendable {
    case assemblyAI = "assemblyai"
    case openAI = "openai"
    case elevenLabs = "elevenlabs"
    case fishAudio = "fishaudio"

    /// The provider a configuration names, with anything unknown meaning the
    /// one the setup window defaults to.
    init(provider: String) {
        self = CloudService(rawValue: provider) ?? .assemblyAI
    }

    func key() -> String? {
        switch self {
        case .assemblyAI: return Config.assemblyAIKey()
        case .openAI: return Config.openAIKey()
        case .elevenLabs: return Config.elevenLabsKey()
        case .fishAudio: return Config.fishAudioKey()
        }
    }

    /// Each API spells the header differently, and a key sent under the wrong
    /// one is answered with a 401 that reads exactly like a bad key.
    func authorize(_ request: inout URLRequest, key: String) {
        switch self {
        case .assemblyAI: request.setValue(key, forHTTPHeaderField: "authorization")
        case .openAI: request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        case .elevenLabs: request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .fishAudio: request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
    }

    /// A cheap URL to ask "is the API there". Any HTTP answer at all counts,
    /// an unauthorized one included: the question is the network, not the key.
    var probeURL: URL {
        switch self {
        case .assemblyAI: return URL(string: "https://api.assemblyai.com/v2/transcript")!
        case .openAI: return URL(string: "https://api.openai.com/v1/models")!
        case .elevenLabs: return URL(string: "https://api.elevenlabs.io/v1/user")!
        case .fishAudio: return URL(string: "https://api.fish.audio/wallet/self/api-credit")!
        }
    }

    func reachable(session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: probeURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }
}

/// One request to a paid transcription API, shared by the cloud engines.
///
/// Each engine used to call `URLSession.shared` itself and read the status
/// code itself, and all three read it the same wrong way: any status outside
/// 2xx was an error worth retrying, so a revoked key (401) and a file too big
/// to accept (413) were retried at every launch exactly like a server having a
/// bad minute, while the bad minute itself (a 503, a 429 with `Retry-After`)
/// failed the whole transcription on the first answer. This is where the
/// difference is drawn, once:
///
/// - 401 and 403 are the key or the account. Nothing about the recording is
///   wrong, so the session's attempts are not spent on it.
/// - 408, 425, 429 and 5xx are the service, and are asked again after a
///   growing pause, or after the pause the service itself asked for.
/// - every other 4xx is the service refusing this request as it stands, and
///   asking again the same way cannot change the answer.
///
/// The session is a parameter so that a test can put a `URLProtocol` behind
/// it and exercise every one of those answers without a key or a network.
struct CloudHTTP: Sendable {
    struct RetryPolicy: Sendable {
        /// Tries in all, the first included.
        var attempts: Int
        var baseDelay: Duration
        /// The longest pause taken between tries, `Retry-After` included: a
        /// service asking for an hour is answered by failing now and letting
        /// the queue come back to it.
        var maxDelay: Duration

        static let standard = RetryPolicy(
            attempts: 4, baseDelay: .seconds(2), maxDelay: .seconds(300))
        static let once = RetryPolicy(attempts: 1, baseDelay: .zero, maxDelay: .zero)
    }

    enum Failure: TranscriptionFailure, CustomStringConvertible, Equatable {
        /// 401 or 403: the key is missing, wrong, or not allowed this.
        case unauthorized(service: String, what: String, status: Int, body: String)
        /// Any other 4xx: this request, as it stands, will not be accepted.
        case rejected(service: String, what: String, status: Int, body: String)
        /// 408, 425, 429 or 5xx, still so after every retry.
        case unavailable(service: String, what: String, status: Int, body: String)
        /// A success whose body is not what the API documents.
        case malformed(service: String, what: String, body: String)

        var status: Int? {
            switch self {
            case .unauthorized(_, _, let status, _), .rejected(_, _, let status, _),
                 .unavailable(_, _, let status, _):
                return status
            case .malformed: return nil
            }
        }

        /// A refusal is the one answer that cannot change by asking again.
        /// A malformed body is not: it is far more often a truncated or
        /// intercepted response than a service that has changed its format.
        var isPermanent: Bool {
            if case .rejected = self { return !isEnvironmental }
            return false
        }

        /// A key problem is the machine's, not the recording's.
        var isEnvironmental: Bool {
            if case .unauthorized = self { return true }
            if case .rejected(service: "fishaudio", what: _, status: 402, body: _) = self {
                return true
            }
            return false
        }

        var description: String {
            switch self {
            case .unauthorized(let service, let what, let status, let body):
                return "\(service) \(what) refused the API key: HTTP \(status) \(body.prefix(400))"
            case .rejected(let service, let what, let status, let body):
                return "\(service) \(what) was rejected: HTTP \(status) \(body.prefix(400))"
            case .unavailable(let service, let what, let status, let body):
                return "\(service) \(what) failed: HTTP \(status) \(body.prefix(400))"
            case .malformed(let service, let what, let body):
                return "\(service) \(what) returned a body amanu can't read: \(body.prefix(400))"
            }
        }
    }

    enum Body: Sendable {
        case none
        case data(Data)
        /// Streamed from disk: an hour of meeting has no business on the heap.
        case file(URL)
    }

    enum Classification: Equatable {
        case success, unauthorized, rejected, retryable
    }

    let service: CloudService
    let session: URLSession
    let retry: RetryPolicy
    let sleep: @Sendable (Duration) async throws -> Void

    init(
        service: CloudService,
        session: URLSession = .shared,
        retry: RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    /// Send one request with the key on it, retrying what is worth retrying.
    ///
    /// `retryTransportErrors` is off for uploads of a whole meeting: a
    /// connection that dropped once during an hour-long upload is the moment
    /// `auto` should reach for the local engine, not a quarter of an hour of
    /// uploading the same file again.
    func send(
        _ request: URLRequest,
        body: Body = .none,
        key: String,
        what: String,
        retryTransportErrors: Bool = true,
        policy: RetryPolicy? = nil
    ) async throws -> Data {
        let policy = policy ?? retry
        var request = request
        service.authorize(&request, key: key)

        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let response: URLResponse
            do {
                switch body {
                case .none: (data, response) = try await session.data(for: request)
                case .data(let bytes): (data, response) = try await session.upload(for: request, from: bytes)
                case .file(let url): (data, response) = try await session.upload(for: request, fromFile: url)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard retryTransportErrors, attempt < policy.attempts,
                      Self.isTransient(error)
                else { throw error }
                try await sleep(Self.backoff(attempt: attempt, policy: policy))
                continue
            }

            guard let http = response as? HTTPURLResponse else { return data }
            let text = String(decoding: data.prefix(2000), as: UTF8.self)
            switch Self.classify(status: http.statusCode) {
            case .success:
                return data
            case .unauthorized:
                throw Failure.unauthorized(
                    service: service.rawValue, what: what, status: http.statusCode, body: text)
            case .rejected:
                throw Failure.rejected(
                    service: service.rawValue, what: what, status: http.statusCode, body: text)
            case .retryable:
                guard attempt < policy.attempts else {
                    throw Failure.unavailable(
                        service: service.rawValue, what: what, status: http.statusCode, body: text)
                }
                let asked = Self.retryAfter(http)
                try await sleep(min(asked ?? Self.backoff(attempt: attempt, policy: policy),
                                    policy.maxDelay))
            }
        }
    }

    /// Decode a successful body, calling a mismatch what it is rather than
    /// letting a `DecodingError` stand in for a service that answered.
    func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Failure.malformed(
                service: service.rawValue, what: what,
                body: String(decoding: data.prefix(400), as: UTF8.self))
        }
    }

    static func classify(status: Int) -> Classification {
        switch status {
        case 200..<300: return .success
        case 401, 403: return .unauthorized
        case 408, 425, 429, 500..<600: return .retryable
        default: return .rejected
        }
    }

    /// `Retry-After` in either of its two forms: seconds, or an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty
        else { return nil }
        if let seconds = Double(value), seconds >= 0 { return .milliseconds(Int(seconds * 1000)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .milliseconds(Int(max(0, date.timeIntervalSince(now)) * 1000))
    }

    static func backoff(attempt: Int, policy: RetryPolicy) -> Duration {
        let factor = 1 << min(max(0, attempt - 1), 16)
        return min(policy.baseDelay * factor, policy.maxDelay)
    }

    /// Transport failures that say "try again shortly" rather than "there is
    /// no network". An absent network is not retried here: under `auto` that
    /// is the moment to transcribe locally instead.
    static func isTransient(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .badServerResponse]
            .contains(url.code)
    }

    // MARK: - multipart

    /// A multipart form with one file in it, assembled on disk and streamed
    /// from there: the request is as large as the meeting, and the daemon has
    /// no business holding that on the heap while it uploads.
    static func writeMultipart(
        fields: [(String, String)], file: URL, boundary: String, to destination: URL,
        fileField: String = "file"
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for (name, value) in fields {
            let field = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                + "\(value)\r\n"
            try output.write(contentsOf: Data(field.utf8))
        }
        let header = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(fileField)\";"
            + " filename=\"\(file.lastPathComponent)\"\r\n"
            + "Content-Type: \(contentType(for: file))\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    static func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    /// Send a file as a streamed multipart form.
    func sendMultipart(
        to url: URL,
        fields: [(String, String)],
        file: URL,
        fileField: String = "file",
        headers: [(String, String)] = [],
        key: String,
        what: String,
        timeout: TimeInterval
    ) async throws -> Data {
        let boundary = "amanu.\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-\(service.rawValue)-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(
            fields: fields, file: file, boundary: boundary, to: body, fileField: fileField)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = timeout
        return try await send(
            request, body: .file(body), key: key, what: what, retryTransportErrors: false)
    }
}

/// Where the cloud engines keep the server's own answers, so a retry after a
/// crash re-renders from disk instead of uploading and paying again.
///
/// A cache is named for everything that shaped the answer — the engine, its
/// model, the languages it was told to expect, the input it was given — so a
/// session transcribed again with a different model, or after the language
/// setting changed, cannot be handed the old answer under the new name. And
/// a cache lives only as long as the transcription it serves: the coordinator
/// removes it once the transcript is written, and a re-transcription removes
/// it before starting, because a cache is the whole meeting's text and must
/// not outlive the transcript somebody deleted.
enum ProviderCache {
    static let providers = CloudService.allCases.map(\.rawValue)

    /// `transcript.<provider>.<key>[.<suffix>].json`, where the key is a short
    /// digest of `parts`.
    static func url(
        in dir: URL, provider: CloudService, parts: [String], suffix: String? = nil
    ) -> URL {
        let key = digest(parts)
        let name = ["transcript", provider.rawValue, key, suffix].compactMap { $0 }
            .joined(separator: ".") + ".json"
        return dir.appendingPathComponent(name)
    }

    static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Every provider cache in one folder, the ones named before caches were
    /// keyed included.
    static func files(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { name in
            name.hasSuffix(".json")
                && providers.contains { name.hasPrefix("transcript.\($0).") }
        }.sorted().map { dir.appendingPathComponent($0) }
    }
}
