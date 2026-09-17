import AVFoundation
import Foundation

/// WhisperAI, with speaker diarization, over aligned two-channel audio.
///
/// A second cloud provider alongside AssemblyAI, and deliberately built as its
/// twin: the API is the same shape — upload the bytes, create a transcript,
/// poll it — so the differences below are the whole of what is worth reading.
///
/// The name is a collision waiting to happen and is worth saying out loud:
/// `whisper` is the *local* engine in `WhisperEngine.swift`, which downloads a
/// model and never touches the network. `whisperai` is this one, a paid API
/// that uploads the meeting. Nothing about one is true of the other.
///
/// The full API response is cached next to the audio as
/// `transcript.whisperai.multichannel.json`. A retry after a crash re-renders
/// from that file instead of re-uploading and re-paying.
actor WhisperAIEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case http(String, Int, String)
        case transcriptFailed(String)
        case timedOut
        case empty

        /// The same rule AssemblyAI's engine follows — only a verdict about
        /// the *audio* is permanent, because the transcription queue survives
        /// restarts and a temporary failure is re-uploaded and re-paid for at
        /// every launch until the session retires.
        ///
        /// HTTP 413 joins the list here, where AssemblyAI has no equivalent:
        /// WhisperAI caps an upload at 5GB, and a recording over the cap is
        /// over it permanently. Everything else — a missing key, a 500, a
        /// timeout, the 402 that means the month's quota is spent — is about
        /// the request or the account and is worth another go.
        var isPermanent: Bool {
            if case .empty = self { return true }
            if case .http(_, let code, _) = self { return code == 413 }
            if case .transcriptFailed(let message) = self {
                return message.lowercased().contains("no spoken audio")
            }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no WhisperAI API key — put one in \(Config.whisperAIKeyPath.path)"
                    + " (chmod 600), set WHISPERAI_API_KEY, or add"
                    + " transcription.whisperai.api_key to the config"
            case .http(let what, let code, let body):
                return "whisperai \(what) failed: HTTP \(code) \(body.prefix(400))"
            case .transcriptFailed(let message):
                return "whisperai returned an error: \(message)"
            case .timedOut:
                return "whisperai transcript didn't finish within "
                    + "\(Int(WhisperAIEngine.pollTimeout / 3600))h"
            case .empty:
                return "whisperai returned no speech"
            }
        }
    }

    private static let base = URL(string: "https://api.whisperai.com/v1")!
    private static let pollInterval: TimeInterval = 10
    private static let pollTimeout: TimeInterval = 3 * 3600

    nonisolated let name = "whisperai"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .multichannel

    private let apiKey: String
    /// The languages this meeting may be in. Sent as a hint in `prompt`
    /// rather than as `language_code`, for the reason in `requestBody`.
    private let expected: [String]
    private let speechModel: String?
    /// Names from the calendar, set per session by the coordinator.
    private var keyterms: [String] = []

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init() throws {
        guard let key = Config.whisperAIKey() else { throw EngineError.noAPIKey }
        apiKey = key
        expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        speechModel = Config.whisperAISpeechModel()

        let parts = [
            speechModel ?? "default",
            expected.isEmpty ? "auto-detect" : expected.joined(separator: "+"),
        ]
        model = parts.joined(separator: " · ")
    }

    func prepare() async throws {}
    func release() async {}

    func expect(_ terms: [String]) async {
        keyterms = terms
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let audioDuration = try await Self.audioDuration(of: audio)
        let channels = (try? AVAudioFile(forReading: audio))?
            .processingFormat.channelCount ?? 1
        let cache = Self.cacheURL(for: audio)

        let response: TranscriptResponse
        if let cached = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: cached),
           decoded.status == "completed" {
            note("reusing cached \(cache.lastPathComponent)")
            response = decoded
        } else {
            let uploadURL = try await upload(audio)
            let id = try await submit(audioURL: uploadURL, multichannel: channels > 1)
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
                end: audioDuration,
                text: text
            )]
        }
        return ProviderTimestamps.bounded(utterances.map {
            TranscriptSegment(
                start: TimeInterval($0.start) / 1000,
                end: TimeInterval($0.end) / 1000,
                text: $0.text,
                speaker: $0.channelQualifiedSpeaker
            )
        }, duration: audioDuration)
    }

    private static func audioDuration(of audio: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        return duration
    }

    static func cacheURL(for audio: URL) -> URL {
        audio.deletingLastPathComponent()
            .appendingPathComponent("transcript.whisperai.multichannel.json")
    }

    // MARK: - API

    /// Push the file to WhisperAI's own storage and get back the URL to
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

    private func submit(audioURL: String, multichannel: Bool) async throws -> String {
        let body = Self.requestBody(
            audioURL: audioURL,
            expectedLanguages: expected,
            keyterms: keyterms,
            speechModel: speechModel,
            multichannel: multichannel)

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
    ///
    /// The meeting language arrives as a hint, not as a setting.
    ///
    /// WhisperAI has no equivalent of AssemblyAI's `expected_languages`
    /// shortlist: its `language_code` is a hard pin, and a pin on the wrong
    /// language is where an engine returns fluent phonetic garbage instead of
    /// failing — with `keep_audio` off, that transcript is all that survives
    /// the meeting. So detection stays on and the expectation goes into
    /// `prompt`, the free-form context field their own MCP tools expose as
    /// `customPrompt`. That keeps `transcription.language` meaning what it
    /// means everywhere else in amanu: the languages to expect, with the
    /// engine still deciding which one it heard.
    static func requestBody(
        audioURL: String,
        expectedLanguages: [String],
        keyterms: [String] = [],
        speechModel: String?,
        multichannel: Bool = true
    ) -> [String: Any] {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": true,
            "punctuate": true,
            "format_text": true,
            "language_detection": true,
            // speakers_expected is deliberately unset — with multichannel,
            // any hint applies independently to every channel.
        ]
        if multichannel { body["multichannel"] = true }
        if !expectedLanguages.isEmpty {
            body["prompt"] = "A recorded meeting. Expected languages: "
                + expectedLanguages.joined(separator: ", ") + "."
        }
        // The people the calendar says are here. `keyterms_prompt` is the
        // custom-vocabulary field their own MCP tools expose as
        // `importantTerms`; a surname the model has never seen otherwise comes
        // back as whatever it sounds like, differently each time it is said.
        if !keyterms.isEmpty { body["keyterms_prompt"] = keyterms }
        if let speechModel { body["speech_model"] = speechModel }
        return body
    }

    /// Poll until the transcript completes. Returns the decoded response and
    /// the raw bytes, so the cache on disk stays the server's own answer
    /// rather than our re-encoding of it.
    ///
    /// A 429 is not a failure here. WhisperAI throttles this endpoint on the
    /// server precisely because it expects to be polled, so being told to slow
    /// down means the next interval, not a dead transcript we have already
    /// paid for.
    private func poll(id: String) async throws -> (TranscriptResponse, Data) {
        let url = Self.base.appendingPathComponent("transcript").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "authorization")

        let deadline = Date().addingTimeInterval(Self.pollTimeout)
        while Date() < deadline {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 429 {
                try await Task.sleep(for: .seconds(Self.pollInterval))
                continue
            }
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
            throw EngineError.http(what, http.statusCode, message(from: data))
        }
    }

    /// Errors arrive as `{"error": "…"}`. Unwrapping it keeps the log line
    /// readable; anything else is reported verbatim, because an error body we
    /// did not anticipate is exactly the one worth seeing in full.
    static func message(from data: Data) -> String {
        struct ErrorResponse: Decodable { let error: String? }
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let error = decoded.error {
            return error
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Progress goes to stderr; the coordinator owns transcribe.log and only
    /// hears about outcomes.
    private nonisolated func note(_ message: String) {
        FileHandle.standardError.write(Data("whisperai: \(message)\n".utf8))
    }

    /// The slice of the API response amanu uses. Decoding is lenient about the
    /// rest, and has to be: the published schema types `utterances` as bare
    /// objects, so the fields below are the documented AssemblyAI shape this
    /// API mirrors rather than anything WhisperAI has promised.
    struct TranscriptResponse: Decodable {
        struct Utterance: Decodable {
            let speaker: String?
            let channel: Channel?
            let text: String
            let start: Int
            let end: Int

            /// Amanu's side attribution reads the one-based channel off the
            /// front of the speaker label (`1A` is the first voice on channel
            /// one). AssemblyAI writes the label that way and also sends
            /// `channel` beside it; with the shape unpinned here, a plain `A`
            /// is joined to its channel rather than trusted to be one side.
            var channelQualifiedSpeaker: String? {
                guard let speaker else { return channel?.label }
                guard let channel, speaker.first?.isNumber != true else { return speaker }
                return channel.label + speaker
            }
        }

        /// Seen as both a JSON number and a string across this family of APIs,
        /// and pinned to neither by the schema.
        enum Channel: Decodable {
            case number(Int)
            case text(String)

            var label: String {
                switch self {
                case .number(let value): return String(value)
                case .text(let value): return value
                }
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Int.self) {
                    self = .number(value)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }
        }

        let status: String
        let error: String?
        let text: String?
        let audio_duration: Double?
        let utterances: [Utterance]?
    }
}
