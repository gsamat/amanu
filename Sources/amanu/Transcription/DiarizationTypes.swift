import Foundation

struct TranscriptWord: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct SpeakerTurn: Codable, Equatable, Sendable {
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
}

protocol LocalDiarizationRuntime: Sendable {
    func prepare() async throws
    func diarize(_ audio: URL) async throws -> [SpeakerTurn]
    func release() async
}

enum LocalDiarizationRuntimeError: Error, Sendable {
    case noSpeechDetected
}

struct DiarizationSettings: Codable, Equatable, Sendable {
    let enabled: Bool
    let threshold: Double

    init(enabled: Bool = false, threshold: Double = 0.6) {
        self.enabled = enabled
        self.threshold = threshold.isFinite ? min(1.2, max(0.3, threshold)) : 0.6
    }

    private enum CodingKeys: String, CodingKey { case enabled, threshold }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            threshold: try values.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.6)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(threshold, forKey: .threshold)
    }
}
