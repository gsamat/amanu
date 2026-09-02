import Foundation

/// AssemblyAI, with speaker diarization, over aligned two-channel audio.
///
/// The one part of amanu that isn't local: the mix is uploaded, transcribed
/// server-side, and polled until done. In exchange you get a model that
/// handles Russian properly and real diarization — so a call with three people
/// on the far side comes back as three speakers instead of one "them".
///
/// The full API response is cached next to the audio as
/// `transcript.assemblyai.multichannel.json`. A retry after a crash re-renders
/// from that file instead of re-uploading and re-paying.
actor AssemblyAIEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case http(String, Int, String)
        case transcriptFailed(String)
        case timedOut
        case empty

        /// Only "there was no speech in this audio" is permanent: a silent
        /// recording will still be silent tomorrow. Everything else here —
        /// a missing key, an HTTP error, a timeout — is worth another go.
        ///
        /// The server can reach that same verdict before we do, and when it
        /// does it is worth exactly as much as our own: a nineteen-second join
        /// with nobody speaking comes back as `language_detection cannot be
        /// performed on files with no spoken audio`, and retried it uploads
        /// and pays for the same silence twice more before the queue gives up.
        /// The match is deliberately narrow — every other transcript error is
        /// something that happened to the request, not to the audio.
        var isPermanent: Bool {
            if case .empty = self { return true }
            if case .transcriptFailed(let message) = self {
                return message.lowercased().contains("no spoken audio")
            }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no AssemblyAI API key — put one in \(Config.assemblyAIKeyPath.path)"
                    + " (chmod 600), set ASSEMBLYAI_API_KEY, or add"
                    + " transcription.assemblyai.api_key to the config"
            case .http(let what, let code, let body):
                return "assemblyai \(what) failed: HTTP \(code) \(body.prefix(400))"
            case .transcriptFailed(let message):
                return "assemblyai returned an error: \(message)"
            case .timedOut:
                return "assemblyai transcript didn't finish within "
                    + "\(Int(AssemblyAIEngine.pollTimeout / 3600))h"
            case .empty:
                return "assemblyai returned no speech"
            }
        }
    }

    private static let base = URL(string: "https://api.assemblyai.com/v2")!
    private static let pollInterval: TimeInterval = 10
    private static let pollTimeout: TimeInterval = 3 * 3600

    nonisolated let name = "assemblyai"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .multichannel

    private let apiKey: String
    /// The languages this meeting may be in. The API is told to detect within
    /// them rather than to assume the first: `language_code` is a pin, and a
    /// pin on the wrong language is where this engine returns fluent phonetic
    /// garbage instead of failing.
    private let expected: [String]
    private let speechModel: String?

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init() throws {
        guard let key = Config.assemblyAIKey() else { throw EngineError.noAPIKey }
        apiKey = key
        expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        speechModel = Config.assemblyAISpeechModel()

        let parts = [
            speechModel ?? "universal",
            expected.isEmpty ? "auto-detect" : expected.joined(separator: "+"),
        ]
        model = parts.joined(separator: " · ")
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let cache = Self.cacheURL(for: audio)

        let response: TranscriptResponse
        if let cached = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: cached),
           decoded.status == "completed" {
            note("reusing cached \(cache.lastPathComponent)")
            response = decoded
        } else {
            let uploadURL = try await upload(audio)
            let id = try await submit(audioURL: uploadURL)
            note("submitted \(id)")
            let (decoded, raw) = try await poll(id: id)
            try? raw.write(to: cache, options: .atomic)
            response = decoded
        }

        // utterances is the diarized view; text is the flat fallback for a
        // recording where diarization found nothing to split.
        guard let utterances = response.utterances, !utterances.isEmpty else {
            let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw EngineError.empty }
            return [TranscriptSegment(
                start: 0,
                end: response.audio_duration ?? 0,
                text: text
            )]
        }
        return utterances.map {
            TranscriptSegment(
                start: TimeInterval($0.start) / 1000,
                end: TimeInterval($0.end) / 1000,
                text: $0.text,
                speaker: $0.speaker
            )
        }
    }

    static func cacheURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent()
            .appendingPathComponent("transcript.assemblyai.multichannel.json")
    }

    // MARK: - API

    /// Push the file to AssemblyAI's own storage and get back the URL to
    /// transcribe. Streaming from disk keeps a long meeting off the heap.
    private func upload(_ audio: URL) async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        // Uploading an hour of AAC over a bad connection outlasts the 60s default.
        request.timeoutInterval = 900

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: audio)
        try Self.check(response, data, "upload")
        struct UploadResponse: Decodable { let upload_url: String }
        return try JSONDecoder().decode(UploadResponse.self, from: data).upload_url
    }

    private func submit(audioURL: String) async throws -> String {
        let body = Self.requestBody(
            audioURL: audioURL,
            expectedLanguages: expected,
            speechModel: speechModel)

        var request = URLRequest(url: Self.base.appendingPathComponent("transcript"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data, "submit")
        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: data).id
    }

    /// The paid API boundary as plain JSON, kept pure so a test can pin the
    /// channel-separation contract without replacing URLSession with a mock.
    static func requestBody(
        audioURL: String,
        expectedLanguages: [String],
        speechModel: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "multichannel": true,
            "speaker_labels": true,
            "punctuate": true,
            "format_text": true,
            "language_detection": true,
            // speakers_expected is deliberately unset — with multichannel,
            // any hint applies independently to every channel.
        ]
        if let primary = expectedLanguages.first {
            body["language_detection_options"] = [
                "expected_languages": expectedLanguages,
                "fallback_language": primary,
            ]
        }
        if let speechModel { body["speech_model"] = speechModel }
        return body
    }

    /// Poll until the transcript completes. Returns the decoded response and
    /// the raw bytes, so the cache on disk stays the server's own answer
    /// rather than our re-encoding of it.
    private func poll(id: String) async throws -> (TranscriptResponse, Data) {
        let url = Self.base.appendingPathComponent("transcript").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "authorization")

        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.check(response, data, "poll")
            let decoded = try JSONDecoder().decode(TranscriptResponse.self, from: data)
            switch decoded.status {
            case "completed":
                return (decoded, data)
            case "error":
                throw EngineError.transcriptFailed(decoded.error ?? "unknown")
            default:
                try await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
        throw EngineError.timedOut
    }

    private static func check(_ response: URLResponse, _ data: Data, _ what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(
                what,
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    /// Progress goes to stderr; the coordinator owns transcribe.log and only
    /// hears about outcomes.
    private nonisolated func note(_ message: String) {
        FileHandle.standardError.write(Data("assemblyai: \(message)\n".utf8))
    }

    /// The slice of the API response amanu uses. Decoding is lenient about the
    /// rest — AssemblyAI adds fields regularly and none of them are our
    /// business.
    private struct TranscriptResponse: Decodable {
        struct Utterance: Decodable {
            let speaker: String?
            let text: String
            let start: Int
            let end: Int
        }

        let status: String
        let error: String?
        let text: String?
        let audio_duration: Double?
        let utterances: [Utterance]?
    }
}
