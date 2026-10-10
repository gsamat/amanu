import CryptoKit
import Foundation

enum DiarizationArtifacts {
    static let asrFile = "asr.json"
    static let timelineFile = "diarization.json"
    static let candidateFile = ".diarization-candidate.json"

    struct ASR: Codable {
        let schemaVersion: Int
        let transcriptSHA256: String
        let engine: String
        let model: String
        let optionsFingerprint: String
        let tracks: [Track]

        struct Track: Codable {
            let speaker: String
            let sourceFingerprint: String
            let sampleCount: Int64
            let clock: DiarizationAudioSource.Clock
            let originFingerprint: String?
            let originFile: String?
            let originChannel: Int?
            let sourceKind: String?
            let segments: [TranscriptSegment]
        }

        init(transcriptSHA256: String, engine: String, model: String,
             optionsFingerprint: String, tracks: [Track]) {
            schemaVersion = 1
            self.transcriptSHA256 = transcriptSHA256
            self.engine = engine
            self.model = model
            self.optionsFingerprint = optionsFingerprint
            self.tracks = tracks
        }

        func rebound(to transcriptSHA256: String) -> Self {
            Self(transcriptSHA256: transcriptSHA256, engine: engine, model: model,
                 optionsFingerprint: optionsFingerprint, tracks: tracks)
        }

        func replacing(_ track: Track, transcriptSHA256: String) -> Self {
            Self(transcriptSHA256: transcriptSHA256, engine: engine, model: model,
                 optionsFingerprint: optionsFingerprint,
                 tracks: tracks.filter { $0.speaker != track.speaker } + [track])
        }

        func cached(speaker: String, sourceFingerprint: String,
                    optionsFingerprint: String, engine: String, model: String) -> [TranscriptSegment]? {
            guard schemaVersion == 1, self.engine == engine, self.model == model,
                  self.optionsFingerprint == optionsFingerprint
            else { return nil }
            return tracks.first { $0.speaker == speaker && $0.sourceFingerprint == sourceFingerprint }?.segments
        }
    }

    struct Timeline<Result: Codable>: Codable {
        let schemaVersion: Int
        let transcriptSHA256: String
        let generationFingerprint: String
        let result: Result

        init(transcriptSHA256: String, generationFingerprint: String, result: Result) {
            schemaVersion = 1
            self.transcriptSHA256 = transcriptSHA256
            self.generationFingerprint = generationFingerprint
            self.result = result
        }
    }

    static func readASR(_ dir: URL) -> ASR? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(asrFile)),
              let transcript = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
              let sidecar = try? JSONDecoder().decode(ASR.self, from: data),
              sidecar.schemaVersion == 1,
              sidecar.transcriptSHA256 == sha256(transcript)
        else { return nil }
        return sidecar
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func hash(_ parts: String...) -> String {
        let content = parts.joined(separator: "\u{1f}")
        return sha256(Data(content.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            try Task<Never, Never>.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func transcriptHash(_ transcript: Transcript) throws -> String {
        sha256(try encode(transcript))
    }
}
