import AVFoundation
import Foundation

/// Scribe v2 over the session's aligned stereo archive. Each channel is
/// extracted and transcribed with diarization, so several people sharing the
/// far channel stay separate. A mono import is sent as-is.
actor ElevenLabsEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case http(Int, String)
        case empty

        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no ElevenLabs API key — put one in \(Config.elevenLabsKeyPath.path)"
                    + " (chmod 600), set ELEVENLABS_API_KEY, or configure"
                    + " transcription.elevenlabs.api_key_path"
            case .http(let code, let body):
                return "elevenlabs transcription failed: HTTP \(code) \(body.prefix(400))"
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

    init() throws {
        guard let key = Config.elevenLabsKey() else { throw EngineError.noAPIKey }
        apiKey = key
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
            let cache = audio.deletingLastPathComponent().appendingPathComponent(
                Self.cacheName(
                    audio: audio.deletingPathExtension().lastPathComponent,
                    channel: channel))
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
                let data = try await send(upload)
                response = try JSONDecoder().decode(Response.self, from: data)
                try? data.write(to: cache, options: .atomic)
            }
            all += Self.segments(from: response, duration: duration, channel: channel)
        }
        guard !all.isEmpty else { throw EngineError.empty }
        return all.sorted { $0.start < $1.start }
    }

    static func cacheName(audio: String, channel: Int?) -> String {
        "transcript.elevenlabs.\(audio)"
            + (channel.map { ".channel\($0 + 1)" } ?? "") + ".json"
    }

    static func requestFields() -> [(String, String)] {
        [
            ("model_id", "scribe_v2"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
            ("diarize", "true"),
        ]
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

    /// Assemble word timestamps into short turns. Prefix speaker labels from
    /// stereo tracks with their one-based channel number for the coordinator.
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
        var active: [String: Turn] = [:]
        var completed: [Turn] = []
        var lastSpeaker: String?
        for word in response.words {
            guard word.start.isFinite, word.end.isFinite else { continue }
            let rawSpeaker = word.speaker_id ?? lastSpeaker ?? "speaker"
            let speaker = channel.map {
                String($0 + 1) + speakerSuffix(rawSpeaker)
            } ?? rawSpeaker
            if word.type == "spacing" {
                if var turn = active[speaker] {
                    turn.text += word.text
                    active[speaker] = turn
                }
                continue
            }
            guard word.type == "word" else { continue }
            let start = max(0, word.start)
            let end = min(duration, word.end)
            guard start < duration, end > start else { continue }
            lastSpeaker = rawSpeaker
            if var turn = active[speaker], start - turn.end <= 1.5 {
                turn.text += word.text
                turn.end = max(turn.end, end)
                active[speaker] = turn
            } else {
                if let previous = active.removeValue(forKey: speaker) {
                    completed.append(previous)
                }
                active[speaker] = Turn(start: start, end: end, text: word.text, speaker: speaker)
            }
        }
        completed += active.values
        let segments: [TranscriptSegment] = completed.sorted { $0.start < $1.start }.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: turn.start, end: turn.end, text: text, speaker: turn.speaker)
        }
        if !segments.isEmpty { return segments }
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            start: 0, end: duration, text: text,
            speaker: channel.map { String($0 + 1) } ?? "speaker")]
    }

    private static func speakerSuffix(_ speaker: String) -> String {
        guard speaker.hasPrefix("speaker_"),
              let index = Int(speaker.dropFirst("speaker_".count)),
              (0..<32).contains(index)
        else { return speaker == "speaker" ? "" : " \(speaker)" }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < 26 ? String(letters[index]) : "A\(letters[index - 26])"
    }

    private func send(_ audio: URL) async throws -> Data {
        let boundary = "amanu.\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-elevenlabs-\(UUID().uuidString).multipart")
        try Self.writeMultipart(
            fields: Self.requestFields(), file: audio,
            boundary: boundary, to: body)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 1800

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func writeMultipart(
        fields: [(String, String)], file: URL, boundary: String, to destination: URL
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
            + "Content-Disposition: form-data; name=\"file\";"
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

    private static func contentType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }
}
