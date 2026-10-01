import AVFoundation
import CryptoKit
import Foundation

/// AssemblyAI, with speaker diarization, over aligned two-channel audio.
///
/// The one part of amanu that isn't local: the mix is uploaded, transcribed
/// server-side, and polled until done. In exchange you get a model that
/// handles Russian properly and real diarization — so a call with three people
/// on the far side comes back as three speakers instead of one "them".
///
/// Two files beside the audio keep a retry from paying twice. The job id is
/// written the moment the transcript is submitted, so an attempt that died
/// while polling — a crash, a quit, a network that went away for longer than
/// the poll would wait — resumes polling that job rather than uploading the
/// meeting again. And the full response is cached once it completes, so a
/// retry after that re-renders from disk. Both are named for the request that
/// produced them (see `ProviderCache`).
actor AssemblyAIEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case transcriptFailed(String)
        case timedOut
        case empty

        /// Only "there was no speech in this audio" is permanent: a silent
        /// recording will still be silent tomorrow. Everything else here —
        /// a missing key, a timeout — is worth another go.
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

        var isEnvironmental: Bool {
            if case .noAPIKey = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no AssemblyAI API key — put one in \(Config.assemblyAIKeyPath.path)"
                    + " (chmod 600), set ASSEMBLYAI_API_KEY, or add"
                    + " transcription.assemblyai.api_key to the config"
            case .transcriptFailed(let message):
                return "assemblyai returned an error: \(message)"
            case .timedOut:
                return "assemblyai transcript didn't finish in time — the job is kept, "
                    + "and the next attempt goes on waiting for it rather than uploading again"
            case .empty:
                return "assemblyai returned no speech"
            }
        }
    }

    struct Timing: Sendable {
        var pollInterval: Duration = .seconds(10)
        /// How long one attempt waits for a submitted job. Not the job's
        /// deadline: the id is kept, and the next attempt waits again.
        var pollTimeout: TimeInterval = 3 * 3600
        /// Poll failures in a row — the network gone, the service erroring —
        /// that are sat out, each after a longer pause, before the attempt
        /// gives up. Twelve comes to about forty minutes.
        var tolerablePollFailures = 12
        var maxPollBackoff: Duration = .seconds(300)
    }

    private static let base = URL(string: "https://api.assemblyai.com/v2")!

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
    private let http: CloudHTTP
    private let timing: Timing

    /// Throws rather than failing at transcribe time — a missing key should
    /// show up in the log the moment the engine is picked, not an upload later.
    init(
        apiKey: String? = nil,
        session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        timing: Timing = Timing(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let key = apiKey ?? Config.assemblyAIKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        expected = MeetingLanguages.expected(primary: Config.transcriptionLanguage())
        speechModel = Config.assemblyAISpeechModel()
        http = CloudHTTP(service: .assemblyAI, session: session, retry: retry, sleep: sleep)
        self.timing = timing

        let parts = [
            speechModel ?? "universal",
            expected.isEmpty ? "auto-detect" : expected.joined(separator: "+"),
        ]
        model = parts.joined(separator: " · ")
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let audioDuration = try await Self.audioDuration(of: audio)
        // Read, not guessed: a file AVFoundation cannot open used to be taken
        // for mono, which turned channel-qualified labels into bare "A" and
        // "B" and quietly switched off the echo filter downstream.
        let channels = try AVAudioFile(forReading: audio).processingFormat.channelCount
        let multichannel = channels > 1
        let cache = cacheURL(for: audio, multichannel: multichannel)
        let job = cache.deletingPathExtension().appendingPathExtension("job.json")

        let response: TranscriptResponse
        if let cached = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(TranscriptResponse.self, from: cached),
           decoded.status == "completed" {
            note("reusing cached \(cache.lastPathComponent)")
            response = decoded
        } else {
            let (decoded, raw) = try await result(of: audio, multichannel: multichannel, job: job)
            try? raw.write(to: cache, options: .atomic)
            try? FileManager.default.removeItem(at: job)
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
        return Self.boundedSegments(utterances.map {
            TranscriptSegment(
                start: TimeInterval($0.start) / 1000,
                end: TimeInterval($0.end) / 1000,
                text: $0.text,
                speaker: $0.speaker
            )
        }, duration: audioDuration)
    }

    /// The completed response for this audio: from a job an earlier attempt
    /// submitted when the service still knows it, from a new upload otherwise.
    ///
    /// A job belongs to the key that submitted it. Asked about with another
    /// key — the person pasted a new one, or moved to another account — the
    /// service answers 401 or 403, and a refused key is the machine's fault,
    /// not the recording's, so the session used to be held for ever over a
    /// job only the old key could see. The job file carries a digest of its
    /// key and is dropped when the key has changed; and a resumed poll the
    /// service refuses or no longer knows is taken for a job that is gone.
    private func result(
        of audio: URL, multichannel: Bool, job: URL
    ) async throws -> (TranscriptResponse, Data) {
        if let submitted = Self.submittedJob(at: job) {
            if let key = submitted.keyDigest, key != Self.digest(of: apiKey) {
                note("\(submitted.id) was submitted with another key — submitting again")
                try? FileManager.default.removeItem(at: job)
            } else {
                note("resuming \(submitted.id)")
                do {
                    return try await poll(id: submitted.id, job: job)
                } catch let failure as CloudHTTP.Failure
                    where [401, 403, 404].contains(failure.status ?? 0) {
                    // Expired, deleted, or not this key's to see. The upload
                    // is the only way back to a transcript.
                    note("\(submitted.id) is gone (\(failure)) — submitting again")
                    try? FileManager.default.removeItem(at: job)
                }
            }
        }
        let uploadURL = try await upload(audio)
        let id = try await submit(audioURL: uploadURL, multichannel: multichannel)
        note("submitted \(id)")
        // Written before the first poll, which is the whole point of it: the
        // transcript is being paid for from this moment on.
        try? JSONSerialization.data(withJSONObject: ["id": id, "key": Self.digest(of: apiKey)])
            .write(to: job, options: .atomic)
        return try await poll(id: id, job: job)
    }

    /// Enough of a key to tell it from another, and nothing a reader of the
    /// folder could use.
    static func digest(of key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A job that ended in an error will end in the same error however often
    /// it is asked about, so it is forgotten and the next attempt submits anew.
    private func poll(id: String, job: URL) async throws -> (TranscriptResponse, Data) {
        do {
            return try await poll(id: id)
        } catch let error as EngineError {
            if case .transcriptFailed = error { try? FileManager.default.removeItem(at: job) }
            throw error
        }
    }

    /// The job an earlier attempt submitted, and the digest of the key it
    /// was submitted with — nil in a file written before that was recorded.
    private static func submittedJob(at url: URL) -> (id: String, keyDigest: String?)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty
        else { return nil }
        return (id, json["key"] as? String)
    }

    /// Provider timestamps are untrusted data. AssemblyAI has returned an
    /// utterance almost thirty seconds beyond a real 35-second file, and that
    /// text otherwise becomes a plausible-looking part of the transcript.
    static func boundedSegments(
        _ segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [TranscriptSegment] {
        guard duration.isFinite, duration > 0 else { return [] }
        return segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite else { return nil }
            let start = max(0, segment.start)
            let end = min(duration, segment.end)
            guard start < duration, end > start else { return nil }
            return TranscriptSegment(
                start: start,
                end: end,
                text: segment.text,
                speaker: segment.speaker)
        }
    }

    private static func audioDuration(of audio: URL) async throws -> TimeInterval {
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        return duration
    }

    /// Where the response for this audio, under these settings, is cached.
    func cacheURL(for audio: URL, multichannel: Bool) -> URL {
        ProviderCache.url(
            in: audio.deletingLastPathComponent(), provider: .assemblyAI,
            parts: [
                "code-switching-v1", audio.lastPathComponent, speechModel ?? "universal",
                expected.joined(separator: "+"), multichannel ? "multichannel" : "mono",
            ])
    }

    // MARK: - API

    /// Push the file to AssemblyAI's own storage and get back the URL to
    /// transcribe. Streaming from disk keeps a long meeting off the heap.
    private func upload(_ audio: URL) async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("upload"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        // Uploading an hour of AAC over a bad connection outlasts the 60s default.
        request.timeoutInterval = 900

        let data = try await http.send(
            request, body: .file(audio), key: apiKey, what: "upload",
            retryTransportErrors: false)
        struct UploadResponse: Decodable { let upload_url: String }
        return try http.decode(UploadResponse.self, from: data, what: "upload").upload_url
    }

    private func submit(audioURL: String, multichannel: Bool) async throws -> String {
        let body = Self.requestBody(
            audioURL: audioURL,
            expectedLanguages: expected,
            speechModel: speechModel,
            multichannel: multichannel)

        var request = URLRequest(url: Self.base.appendingPathComponent("transcript"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await http.send(request, key: apiKey, what: "submit")
        struct CreateResponse: Decodable { let id: String }
        return try http.decode(CreateResponse.self, from: data, what: "submit").id
    }

    /// The paid API boundary as plain JSON, kept pure so a test can pin the
    /// channel-separation contract without replacing URLSession with a mock.
    static func requestBody(
        audioURL: String,
        expectedLanguages: [String],
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
        // Detection alone selects the dominant language. Universal-2 needs
        // this option even when the user has chosen automatic detection.
        var detection: [String: Any] = ["code_switching": true]
        if let primary = expectedLanguages.first {
            detection["expected_languages"] = expectedLanguages
            detection["fallback_language"] = primary
        }
        body["language_detection_options"] = detection
        if let speechModel { body["speech_model"] = speechModel }
        return body
    }

    /// Poll until the transcript completes. Returns the decoded response and
    /// the raw bytes, so the cache on disk stays the server's own answer
    /// rather than our re-encoding of it.
    ///
    /// A poll is a free GET against a job already paid for, so a failed one
    /// is sat out rather than given up on: a network that dropped for a few
    /// minutes used to cost the job, and the next attempt uploaded and paid
    /// for the meeting again. Only a run of failures long enough to mean
    /// something ends the attempt — and even then the job id stays on disk
    /// for the next one.
    private func poll(id: String) async throws -> (TranscriptResponse, Data) {
        let url = Self.base.appendingPathComponent("transcript").appendingPathComponent(id)
        let request = URLRequest(url: url)

        let deadline = Date().addingTimeInterval(timing.pollTimeout)
        var failures = 0
        while Date() < deadline {
            let data: Data
            do {
                data = try await http.send(request, key: apiKey, what: "poll", policy: .once)
                failures = 0
            } catch let failure as CloudHTTP.Failure {
                guard case .unavailable = failure else { throw failure }
                try await sitOut(failure, after: &failures)
                continue
            } catch let error as URLError {
                try await sitOut(error, after: &failures)
                continue
            }
            let decoded = try http.decode(TranscriptResponse.self, from: data, what: "poll")
            switch decoded.status {
            case "completed":
                return (decoded, data)
            case "error":
                throw EngineError.transcriptFailed(decoded.error ?? "unknown")
            default:
                try await http.sleep(timing.pollInterval)
            }
        }
        throw EngineError.timedOut
    }

    private func sitOut(_ error: Error, after failures: inout Int) async throws {
        failures += 1
        guard failures <= timing.tolerablePollFailures else { throw error }
        note("poll failed (\(error)) — asking again shortly")
        let pause = timing.pollInterval * (1 << min(failures, 16))
        try await http.sleep(min(pause, timing.maxPollBackoff))
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
