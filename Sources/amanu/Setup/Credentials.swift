import Foundation

/// The keys amanu holds for other services: where each one lives, whether it
/// is there, and how to ask the service whether it still works.
///
/// Kept out of the setup form because none of it is about a window. The form
/// asks and draws; what it asks is answered here, where it can be checked
/// without building one.
enum Credentials {
    /// Whether the cloud transcription provider has a key to work with.
    static func hasTranscriptionKey(for provider: String) -> Bool {
        switch provider {
        case "openai": return Config.openAIKey() != nil
        case "elevenlabs": return Config.elevenLabsKey() != nil
        case "fishaudio": return Config.fishAudioKey() != nil
        default: return Config.assemblyAIKey() != nil
        }
    }

    // MARK: - where a key lives

    /// The file a key for one purpose is read from, and so the one a key
    /// pasted for that purpose has to be written to.
    ///
    /// Written anywhere else, a key is a key nothing reads while the window
    /// says it works — which is what happened to a person whose config named
    /// `summary.openai_api_key_path`: every key they pasted went to amanu's
    /// own file, and every summary went on reading the other one.
    struct Slot: Equatable {
        let path: URL
        /// The person named this file in the config rather than amanu
        /// choosing it.
        let isNamedInConfig: Bool

        /// Whether amanu may write here. Only its own drawer: a file the
        /// config names can be one several tools share, and `docs/pitfalls.md`
        /// says what writing to one of those cost once.
        var isAmanus: Bool {
            let drawer = Config.keysDir.standardizedFileURL.path + "/"
            return path.standardizedFileURL.path.hasPrefix(drawer)
        }
    }

    /// Where the summary's OpenAI-compatible key lives when the endpoint is
    /// not OpenAI's own. A slot of its own, because the key for OpenRouter or
    /// Groq is not an OpenAI key, and writing it over the OpenAI one — which
    /// the OpenAI transcription engine reads — turned every transcript after
    /// it into an HTTP 401.
    static var openAICompatibleKeyPath: URL {
        Config.keysDir.appendingPathComponent("openai-compatible")
    }

    /// Whether a base URL is OpenAI's own API, where the one OpenAI key is
    /// the right key for summaries and transcription alike.
    static func isOpenAIItself(_ baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.host?.lowercased() == "api.openai.com"
    }

    /// The file a cloud transcription key is read from.
    static func transcriptionSlot(for provider: String, in config: [String: Any]?) -> Slot {
        switch provider {
        case "openai":
            if let named = Config.openAIKeyFile(in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: Config.openAIKeyPath, isNamedInConfig: false)
        case "elevenlabs":
            if let named = pathSetting(.elevenLabsKeyPath, in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: Config.elevenLabsKeyPath, isNamedInConfig: false)
        case "fishaudio":
            if let named = pathSetting(.fishAudioKeyPath, in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: Config.fishAudioKeyPath, isNamedInConfig: false)
        default:
            if let named = pathSetting(.assemblyAIKeyPath, in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: Config.assemblyAIKeyPath, isNamedInConfig: false)
        }
    }

    /// The file the summary's own-key backend is read from: `anthropic-api`
    /// or `openai-api`.
    ///
    /// For `openai-api` the answer depends on where the Base URL points.
    /// OpenAI's own API takes the OpenAI key, from `summary.openai_api_key_path`
    /// or wherever transcription reads it. Any other server takes a key of
    /// its own, from `summary.openai_compatible_api_key_path` or the file a
    /// key pasted for it goes to — never a file that holds the OpenAI key.
    static func summarySlot(for backend: String, in config: [String: Any]?) -> Slot {
        if backend == "anthropic-api" {
            if let named = pathSetting(.summaryKeyPath, in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: Config.anthropicKeyPath, isNamedInConfig: false)
        }
        let baseURL = Config.summary(in: config).openAIBaseURL
        guard isOpenAIItself(baseURL) else {
            if let named = pathSetting(.summaryOpenAICompatibleKeyPath, in: config) {
                return Slot(path: named, isNamedInConfig: true)
            }
            return Slot(path: openAICompatibleKeyPath, isNamedInConfig: false)
        }
        if let named = pathSetting(.summaryOpenAIKeyPath, in: config) {
            return Slot(path: named, isNamedInConfig: true)
        }
        return transcriptionSlot(for: "openai", in: config)
    }

    /// The key the summary's `openai-api` backend sends.
    ///
    /// To OpenAI itself, the OpenAI key: the file `summary.openai_api_key_path`
    /// names, or else the one transcription uses. To any other endpoint, the
    /// key `summary.openai_compatible_api_key_path` names, or else the one
    /// pasted for it. The OpenAI key is offered as a last resort only to a
    /// server on this Mac: handing it to OpenRouter or Groq would give a third
    /// party a secret it has no use for, just because a base URL was changed.
    /// `summary.openai_api_key_path` is never read for another server, since
    /// it has always been the OpenAI key's setting and in a config written
    /// before the Base URL changed it still names that key.
    static func summaryOpenAIKey(in config: [String: Any]? = Config.raw()) -> String? {
        let baseURL = Config.summary(in: config).openAIBaseURL
        if isOpenAIItself(baseURL) {
            // OPENAI_API_KEY wins over a named file, as it does for
            // transcription.
            if Home.current.variable("OPENAI_API_KEY")?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return Config.openAIKey()
            }
            if let named = pathSetting(.summaryOpenAIKeyPath, in: config) {
                return Config.secret(at: named)
            }
            return Config.openAIKey()
        }
        if let named = pathSetting(.summaryOpenAICompatibleKeyPath, in: config) {
            return Config.secret(at: named)
        }
        if let pasted = Config.secret(at: openAICompatibleKeyPath) { return pasted }
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?.lowercased() ?? ""
        return OpenAICompatible.isLoopback(host) ? Config.openAIKey() : nil
    }

    private static func pathSetting(_ key: Config.Key, in config: [String: Any]?) -> URL? {
        Config.text(key, in: config).map { Home.current.expanding($0) }
    }

    // MARK: - writing one

    /// A key is a secret: it goes to a file only its owner can read, never
    /// into the config file — which the settings window shows on screen. The
    /// directory is amanu's own and mode 0700, so a key pasted here can't be
    /// overwritten by some other tool that keeps its secrets in the same place.
    static func writeSecret(_ value: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(value.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Why a key was not written to a file the config names: amanu writes
    /// only into its own drawer, so the person is told where to put it.
    static func notOursToWrite(_ slot: Slot) -> String {
        let shown = Home.current.abbreviating(slot.path.path)
        return localised(
            "your config reads this key from \(shown) — put it there yourself",
            "в конфиге ключ читается из \(shown) — положите его туда сами")
    }

    // MARK: - asking the service

    /// What a service said about a key.
    ///
    /// Four answers and not two. A key check that could only say yes or no
    /// told somebody on a train that the key they had just copied from the
    /// dashboard was refused — the request never left the Mac, and nothing
    /// about the key had been learned at all.
    enum Verdict: Equatable, Sendable {
        case works
        /// The service answered, and said no.
        case refused
        /// No answer: offline, a name that would not resolve, a timeout.
        case unreachable
        /// An answer that is neither — a server error, a rate limit, an
        /// endpoint that is not there.
        case unexpected(status: Int)

        /// Said beside the key field. `saved` is whether a key was already on
        /// disk, because that is the one thing the person needs to know is
        /// still true.
        func sentence(keepingSaved saved: Bool) -> String {
            switch self {
            case .works:
                return localised("key works", "ключ работает")
            case .refused:
                return saved
                    ? localised(
                        "that key was refused — the saved one is untouched",
                        "этот ключ не приняли — сохранённый не тронут")
                    : localised("that key was refused", "этот ключ не приняли")
            case .unreachable:
                return localised(
                    "couldn't reach the service to check the key — nothing was saved",
                    "не удалось связаться с сервисом, чтобы проверить ключ, — ничего не сохранено")
            case .unexpected(let status):
                return localised(
                    "the service answered \(status) — nothing was saved; try again later",
                    "сервис ответил \(status) — ничего не сохранено; попробуйте позже")
            }
        }
    }

    /// The answer an HTTP status amounts to. `accepted` is the status a
    /// working key gets, which is not always 200 — see `elevenLabs`.
    static func verdict(status: Int?, accepted: Set<Int> = [200]) -> Verdict {
        guard let status else { return .unreachable }
        if accepted.contains(status) { return .works }
        if status == 401 || status == 403 { return .refused }
        return .unexpected(status: status)
    }

    /// Send a key check and say what came back. Any failure to get an answer
    /// at all is `unreachable`: URLSession throws for a network that is not
    /// there and never for a status code, which is exactly the line between
    /// "we could not ask" and "we were told no".
    static func ask(
        _ request: URLRequest,
        accepting accepted: Set<Int> = [200],
        session: URLSession = .shared
    ) async -> Verdict {
        do {
            let (_, response) = try await session.data(for: request)
            return verdict(status: (response as? HTTPURLResponse)?.statusCode, accepted: accepted)
        } catch {
            return .unreachable
        }
    }

    /// One question for one service: is this key any good.
    struct Check: Equatable, Sendable {
        enum Service: Equatable, Sendable {
            case assemblyAI
            case elevenLabs
            case fishAudio
            case anthropic
            case openAI(baseURL: String)
        }

        let service: Service
        let key: String

        func ask(session: URLSession = .shared) async -> Verdict {
            switch service {
            case .assemblyAI: return await Credentials.assemblyAI(key, session: session)
            case .elevenLabs: return await Credentials.elevenLabs(key, session: session)
            case .fishAudio: return await Credentials.fishAudio(key, session: session)
            case .anthropic:
                return await SummaryKeyProbe.check(provider: .anthropic, key: key, session: session)
            case .openAI(let baseURL):
                return await SummaryKeyProbe.check(
                    provider: .openAI, key: key, openAIBaseURL: baseURL, session: session)
            }
        }
    }

    /// Ask AssemblyAI whether it knows this key, now, rather than finding out
    /// after a meeting. The cheapest authenticated call it has.
    static func assemblyAI(_ key: String, session: URLSession = .shared) async -> Verdict {
        var request = URLRequest(
            url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "authorization")
        return await ask(request, session: session)
    }

    static func elevenLabs(_ key: String, session: URLSession = .shared) async -> Verdict {
        // Restricted keys can transcribe without permission to read /v1/user.
        // Submit no file to the STT endpoint: a permitted key gets validation
        // error 422, an invalid key gets 401, and nothing is transcribed.
        let boundary = "amanu-key-check"
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"model_id\"\r\n\r\n"
            + "scribe_v2\r\n--\(boundary)--\r\n").utf8)
        return await ask(request, accepting: [422], session: session)
    }

    /// Check authentication without uploading audio or requiring a positive balance.
    static func fishAudio(_ key: String, session: URLSession = .shared) async -> Verdict {
        var request = URLRequest(
            url: URL(string: "https://api.fish.audio/wallet/self/api-credit")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        return await ask(request, session: session)
    }
}

/// A no-cost authentication check for the two summary API providers. Both
/// official APIs expose an authenticated model-list endpoint, so setup can
/// verify a key without generating (and billing for) any text.
enum SummaryKeyProbe {
    enum Provider {
        case anthropic
        case openAI
    }

    static func request(
        provider: Provider,
        key: String,
        openAIBaseURL: String = "https://api.openai.com/v1"
    ) -> URLRequest {
        let url: URL
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        case .openAI:
            url = OpenAICompatible.endpoint(baseURL: openAIBaseURL, path: "models")
                ?? URL(string: "about:blank")!
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    static func check(
        provider: Provider,
        key: String,
        openAIBaseURL: String = "https://api.openai.com/v1",
        session: URLSession = .shared
    ) async -> Credentials.Verdict {
        await Credentials.ask(
            request(provider: provider, key: key, openAIBaseURL: openAIBaseURL),
            session: session)
    }
}
