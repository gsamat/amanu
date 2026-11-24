import AVFoundation
import Foundation

/// Scribe v2 over the session's aligned stereo archive. Each channel is
/// extracted and transcribed with diarization, so several people sharing the
/// far channel stay separate. A mono import is sent as-is.
actor ElevenLabsEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case empty

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
                return "no ElevenLabs API key — put one in \(Config.elevenLabsKeyPath.path)"
                    + " (chmod 600), set ELEVENLABS_API_KEY, or configure"
                    + " transcription.elevenlabs.api_key_path"
            case .empty:
                return "elevenlabs returned no speech"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    nonisolated let name = "elevenlabs"
    nonisolated let model = "scribe_v2"
    nonisolated let input: TranscriptionInput = .multichannel

    private let apiKey: String
    private let http: CloudHTTP
    private let fixedLanguage: String?

    init(
        apiKey: String? = nil,
        session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        let policy = Config.transcriptionLanguagePolicy(for: "elevenlabs")
        try policy.validate(engine: "elevenlabs", model: "scribe_v2")
        guard let key = apiKey ?? Config.elevenLabsKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        fixedLanguage = policy.fixedLanguage
        http = CloudHTTP(service: .elevenLabs, session: session, retry: retry, sleep: sleep)
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        let channels = Int((try AVAudioFile(forReading: audio)).processingFormat.channelCount)

        var all: [TranscriptSegment] = []
        for index in 0..<channels {
            let channel: Int? = channels > 1 ? index : nil
            let cache = cacheURL(for: audio, channel: channel)
            let response: Response
            if let cached = try? Data(contentsOf: cache),
               let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
                response = decoded
            } else {
                let upload: URL
                if let channel {
                    upload = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "amanu-elevenlabs-\(UUID().uuidString)-channel\(channel + 1).m4a")
                    do {
                        try await Task.detached(priority: .utility) {
                            try AudioChannelExtractor.extract(
                                channel: channel, from: audio, to: upload)
                        }.value
                    } catch {
                        try? FileManager.default.removeItem(at: upload)
                        throw error
                    }
                } else {
                    upload = audio
                }
                defer {
                    if channel != nil { try? FileManager.default.removeItem(at: upload) }
                }
                let data = try await http.sendMultipart(
                    to: Self.endpoint, fields: Self.requestFields(language: fixedLanguage), file: upload,
                    key: apiKey, what: "transcription", timeout: 1800)
                response = try http.decode(Response.self, from: data, what: "transcription")
                try? data.write(to: cache, options: .atomic)
            }
            all += Self.segments(from: response, duration: duration, channel: channel)
        }
        guard !all.isEmpty else { throw EngineError.empty }
        return all.sorted { $0.start < $1.start }
    }

    /// Where one channel's response is cached: named for the audio, the
    /// model and every field sent with it.
    func cacheURL(for audio: URL, channel: Int?) -> URL {
        ProviderCache.url(
            in: audio.deletingLastPathComponent(), provider: .elevenLabs,
            parts: [audio.lastPathComponent, model]
                + Self.requestFields(language: fixedLanguage).map { "\($0.0)=\($0.1)" },
            suffix: channel.map { "channel\($0 + 1)" })
    }

    static func requestFields(language: String? = nil) -> [(String, String)] {
        var fields = [
            ("model_id", "scribe_v2"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
            ("diarize", "true"),
        ]
        if let language { fields.append(("language_code", language)) }
        return fields
    }

    struct Response: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let type: String
            let speaker_id: String?
        }

        let text: String?
        let words: [Word]
    }

    /// Assemble word timestamps into turns — runs of one speaker's words
    /// with no one else's in between — and label them the way the other
    /// diarizing engines do.
    ///
    /// A turn ends where another voice begins, as AssemblyAI's utterances do.
    /// This used to carry each speaker's turn across the other voices for up
    /// to a second and a half, so the canonical transcript said one person
    /// spoke straight through an interjection that happened in the middle of
    /// their sentence. Merging a brief interruption away is a question of
    /// presentation, and it is answered where AssemblyAI's is: in
    /// transcript.md, from the timestamps kept here.
    ///
    /// Labels are letters, `A` for `speaker_0`, prefixed with the one-based
    /// channel for stereo input, so the coordinator reads `1A` as `me A`
    /// exactly as it does for AssemblyAI. A mono import used to keep
    /// ElevenLabs' own `speaker_0`, where every other engine says `A`.
    static func segments(
        from response: Response, duration: TimeInterval, channel: Int?
    ) -> [TranscriptSegment] {
        struct Turn {
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            let speaker: String
        }

        guard duration.isFinite, duration > 0 else { return [] }
        var turns: [Turn] = []
        var lastSpeaker: String?
        for word in response.words {
            guard word.start.isFinite, word.end.isFinite else { continue }
            let rawSpeaker = word.speaker_id ?? lastSpeaker ?? "speaker"
            let speaker = (channel.map { String($0 + 1) } ?? "") + label(rawSpeaker)
            if word.type == "spacing" {
                if let last = turns.indices.last, turns[last].speaker == speaker {
                    turns[last].text += word.text
                }
                continue
            }
            guard word.type == "word" else { continue }
            let start = max(0, word.start)
            let end = min(duration, word.end)
            guard start < duration, end > start else { continue }
            lastSpeaker = rawSpeaker
            if let last = turns.indices.last, turns[last].speaker == speaker,
               start - turns[last].end <= 1.5 {
                turns[last].text += word.text
                turns[last].end = max(turns[last].end, end)
            } else {
                turns.append(Turn(start: start, end: end, text: word.text, speaker: speaker))
            }
        }
        let segments: [TranscriptSegment] = turns.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: turn.start, end: turn.end, text: text,
                speaker: turn.speaker.isEmpty ? nil : turn.speaker)
        }
        if !segments.isEmpty { return segments }
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            start: 0, end: duration, text: text,
            speaker: channel.map { String($0 + 1) })]
    }

    /// `speaker_0` as `A`, `speaker_27` as `AB`; nothing at all for a word
    /// the service gave no speaker; any other id as it came, with no space
    /// in front of it — `MultichannelSpeakerLabels` puts the one space
    /// between side and voice, and a second made `me  guest`.
    private static func label(_ speaker: String) -> String {
        guard speaker.hasPrefix("speaker_"),
              let index = Int(speaker.dropFirst("speaker_".count)),
              (0..<52).contains(index)
        else { return speaker == "speaker" ? "" : speaker }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < 26 ? String(letters[index]) : "A\(letters[index - 26])"
    }
}
