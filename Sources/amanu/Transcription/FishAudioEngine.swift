import AVFoundation
import Darwin
import Foundation

/// Transcribe-1 Pro over independent, diarized channels. Long channels are
/// cut into bounded AAC requests; a voice label belongs to only one request.
actor FishAudioEngine: TranscriptionEngine {
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
                return "no Fish Audio API key — put one in \(Config.fishAudioKeyPath.path)"
                    + " (chmod 600), set FISH_API_KEY, or configure"
                    + " transcription.fishaudio.api_key_path"
            case .empty:
                return "fishaudio returned no speech"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.fish.audio/v1/asr")!
    /// One second below the API's hour ceiling leaves room for AAC padding.
    static let defaultMaxPieceDuration: TimeInterval = 3599

    nonisolated let name = "fishaudio"
    nonisolated let model = "transcribe-1-pro"
    nonisolated let input: TranscriptionInput = .multichannel

    private let apiKey: String
    private let languageHint: String?
    private let maxPieceDuration: TimeInterval
    private let http: CloudHTTP

    init(
        apiKey: String? = nil,
        session: URLSession = .shared,
        maxPieceDuration: TimeInterval = FishAudioEngine.defaultMaxPieceDuration,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        precondition(maxPieceDuration.isFinite && maxPieceDuration > 0)
        guard let key = apiKey ?? Config.fishAudioKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        languageHint = MeetingLanguages.pin(
            for: MeetingLanguages.expected(primary: Config.transcriptionLanguage()))
        self.maxPieceDuration = maxPieceDuration
        http = CloudHTTP(service: .fishAudio, session: session, retry: retry, sleep: sleep)
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard file.length > 0, format.sampleRate.isFinite, format.sampleRate > 0, channels > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }

        let scratchRoot = audio.deletingLastPathComponent().appendingPathComponent(
            TranscriptionScratch.fishAudioSliceFolder, isDirectory: true)
        let invocation = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: invocation)
            // Unlike recursive removal, rmdir cannot take another invocation
            // that starts using this root while this one is cleaning up.
            _ = Darwin.rmdir(scratchRoot.path)
        }

        var all: [TranscriptSegment] = []
        for index in 0..<channels {
            try Task.checkCancellation()
            let channel: Int? = channels > 1 ? index : nil
            let wholeCacheWasChecked = duration <= maxPieceDuration
            if wholeCacheWasChecked,
               let cached = cachedSegments(
                   at: cacheURL(for: audio, channel: channel, piece: 0, of: 1),
                   duration: duration, offset: 0, channel: channel, piece: nil) {
                all += cached
                continue
            }

            let directory = invocation.appendingPathComponent(
                channel.map { "channel\($0 + 1)" } ?? "mono", isDirectory: true)
            let source: URL
            if let channel {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                source = directory.appendingPathComponent("channel.m4a")
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try AudioChannelExtractor.extract(channel: channel, from: audio, to: source)
                }.value
            } else {
                source = audio
            }

            try Task.checkCancellation()
            let sliced = try await AudioSlicer.slice(
                source, every: maxPieceDuration,
                into: directory.appendingPathComponent("pieces", isDirectory: true))
            // Extraction can leave an AAC-padding-only tail. It is not another
            // source piece, and must not change either cache counts or labels.
            let slices = sliced.filter { $0.offset < duration }
            guard !slices.isEmpty else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
            }
            for (piece, slice) in slices.enumerated() {
                try Task.checkCancellation()
                let nextOffset = piece + 1 < slices.count ? slices[piece + 1].offset : duration
                let pieceDuration = min(nextOffset - slice.offset, duration - slice.offset)
                let labelPiece: Int? = slices.count > 1 ? piece : nil
                let cache = cacheURL(for: audio, channel: channel, piece: piece, of: slices.count)
                // A one-piece cache was already rejected before extraction.
                // Long-input caches need the slicer's actual count and offsets.
                let cached = wholeCacheWasChecked && slices.count == 1 ? nil : cachedSegments(
                    at: cache, duration: pieceDuration, offset: slice.offset,
                    channel: channel, piece: labelPiece)
                if let cached {
                    all += cached
                } else {
                    all += try await sendPiece(
                        slice.url, cache: cache, duration: pieceDuration, offset: slice.offset,
                        channel: channel, piece: labelPiece)
                }
            }
        }
        try Task.checkCancellation()
        guard !all.isEmpty else { throw EngineError.empty }
        return all.sorted { $0.start < $1.start }
    }

    /// Cached silence is a valid answer, distinct from an unreadable or
    /// semantically invalid response that needs to be refreshed.
    private func cachedSegments(
        at cache: URL, duration: TimeInterval, offset: TimeInterval, channel: Int?, piece: Int?
    ) -> [TranscriptSegment]? {
        guard let raw = try? Data(contentsOf: cache),
              let response = try? JSONDecoder().decode(Response.self, from: raw)
        else { return nil }
        return try? Self.segments(
            from: response, duration: duration, offset: offset, channel: channel, piece: piece)
    }

    private func sendPiece(
        _ audio: URL, cache: URL, duration: TimeInterval, offset: TimeInterval,
        channel: Int?, piece: Int?
    ) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let raw = try await http.sendMultipart(
            to: Self.endpoint, fields: requestFields(), file: audio,
            fileField: "audio", headers: [("model", model)], key: apiKey,
            what: "transcription", timeout: 1800)
        let response = try http.decode(Response.self, from: raw, what: "transcription")
        let segments = try Self.segments(
            from: response, duration: duration, offset: offset, channel: channel, piece: piece)
        // Keep the validated paid answer even if a later piece fails or this
        // invocation is cancelled before it can return a complete transcript.
        try? raw.write(to: cache, options: .atomic)
        try Task.checkCancellation()
        return segments
    }

    private func requestFields() -> [(String, String)] {
        var fields = [
            ("ignore_timestamps", "false"),
            ("tag_audio_events", "false"),
            ("diarize", "true"),
        ]
        if let languageHint { fields.append(("language", languageHint)) }
        return fields
    }

    /// Always keyed by the original source, never a UUID-named derived file.
    func cacheURL(for audio: URL, channel: Int?, piece: Int, of count: Int) -> URL {
        ProviderCache.url(
            in: audio.deletingLastPathComponent(), provider: .fishAudio,
            parts: [
                audio.lastPathComponent, model, languageHint ?? "detect", String(maxPieceDuration),
                "channel=\(channel.map { String($0) } ?? "mono")",
                "piece=\(piece + 1)", "count=\(count)",
            ] + requestFields().map { "\($0.0)=\($0.1)" },
            suffix: (channel.map { "channel\($0 + 1)" } ?? "mono") + "-piece\(piece + 1)")
    }

    struct Response: Decodable, Sendable {
        struct Turn: Decodable, Sendable {
            let speaker: String
            let text: String
            let start: TimeInterval
            let end: TimeInterval
        }

        let text: String
        let duration: TimeInterval
        let speaker_turns: [Turn]
    }

    /// Use the service's turns directly: word segments have no speaker IDs,
    /// and full text can contain inline markers that are not utterances.
    static func segments(
        from response: Response, duration: TimeInterval, offset: TimeInterval,
        channel: Int?, piece: Int?
    ) throws -> [TranscriptSegment] {
        guard response.duration.isFinite, response.duration > 0 else {
            throw CloudHTTP.Failure.malformed(
                service: "fishaudio", what: "transcription", body: "invalid transcription duration")
        }
        let prefix = (channel.map { String($0 + 1) } ?? "")
            + (piece.map { "P\($0 + 1)" } ?? "")
        let segments: [TranscriptSegment] = response.speaker_turns.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, turn.start.isFinite, turn.end.isFinite, turn.end > turn.start else {
                return nil
            }
            let start = min(duration, max(0, turn.start))
            let end = min(duration, max(0, turn.end))
            guard end > start else { return nil }
            let shiftedStart = start + offset
            let shiftedEnd = end + offset
            guard shiftedStart.isFinite, shiftedEnd.isFinite, shiftedEnd > shiftedStart else {
                return nil
            }
            return TranscriptSegment(
                start: shiftedStart, end: shiftedEnd, text: text,
                speaker: prefix + label(turn.speaker))
        }
        if segments.isEmpty,
           !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CloudHTTP.Failure.malformed(
                service: "fishaudio", what: "transcription", body: "speech without usable speaker turns")
        }
        return segments
    }

    private static func label(_ speaker: String) -> String {
        guard speaker.hasPrefix("speaker:"),
              let index = Int(speaker.dropFirst("speaker:".count)),
              (0..<52).contains(index)
        else { return speaker }
        let letter = String(UnicodeScalar(65 + index % 26)!)
        return index < 26 ? letter : "A\(letter)"
    }
}
