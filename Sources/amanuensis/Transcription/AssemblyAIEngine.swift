import Foundation

/// AssemblyAI, with speaker diarization, over the mixed-down session audio.
///
/// The one part of amanuensis that isn't local: the mix is uploaded, transcribed
/// server-side, and polled until done. In exchange you get a model that
/// handles Russian properly and real diarization — so a call with three people
/// on the far side comes back as three speakers instead of one "them".
///
/// The full API response is cached next to the audio as
/// `transcript.assemblyai.json`. A retry after a crash re-renders from that
/// file instead of re-uploading and re-paying.
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
        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no AssemblyAI API key — put one in \(Config.assemblyAIDefaultKeyPath.path)"
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
    nonisolated let input: TranscriptionInput = .mixed

    private let apiKey: String
    private let language: String?
    private let speechModel: String?

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init() throws {
        guard let key = Config.assemblyAIKey() else { throw EngineError.noAPIKey }
        apiKey = key
        language = Config.transcriptionLanguage()
        speechModel = Config.assemblyAISpeechModel()

        let parts = [speechModel ?? "universal", language ?? "auto-detect"]
        model = parts.joined(separator: " · ")
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let cache = audio.deletingLastPathComponent()
            .appendingPathComponent("transcript.assemblyai.json")

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
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": true,
            "punctuate": true,
            "format_text": true,
            // speakers_expected is deliberately unset — the model picks the
            // count better unconstrained than we can guess it.
        ]
        if let language {
            body["language_code"] = language
        } else {
            body["language_detection"] = true
        }
        if let speechModel { body["speech_model"] = speechModel }

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

    /// The slice of the API response amanuensis uses. Decoding is lenient about the
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
