import Foundation

/// The requested local stage lives in meta.json so an existing transcript cannot
/// accidentally make an unfinished recording look complete after a restart.
struct DiarizationState: Codable, Equatable {
    enum Status: String, Codable {
        case pending, running, deferred, failed, completed, partial, skipped
        case notApplicable = "not_applicable"
    }

    struct Request: Codable, Equatable {
        let engine: String
        let threshold: Double
        let explicit: Bool

        init(engine: String, threshold: Double, explicit: Bool = false) {
            self.engine = engine
            self.threshold = threshold
            self.explicit = explicit
        }
    }

    static let key = "diarization"
    let request: Request
    var status: Status
    var fingerprint: String?
    var attempts = 0
    var reason: String?
    var rejectedTurnCount: Int?
    var confirmedSpeakers = 0
    var hasUnknown = false

    var isOutstanding: Bool {
        switch status {
        case .pending, .running, .deferred, .partial: true
        case .failed, .completed, .skipped, .notApplicable: false
        }
    }

    var retainsAudio: Bool {
        switch status {
        case .completed, .skipped, .notApplicable: false
        case .pending, .running, .deferred, .failed, .partial: true
        }
    }

    var isFinal: Bool { !retainsAudio }

    init(request: Request, status: Status) {
        self.request = request
        self.status = status
    }

    mutating func beginInference(fingerprint: String) {
        if self.fingerprint != fingerprint { attempts = 0 }
        self.fingerprint = fingerprint
        attempts += 1
        status = .running
        reason = nil
    }

    mutating func failInference(_ reason: String) {
        status = attempts >= 3 ? .failed : .pending
        self.reason = reason
    }

    mutating func deferForEnvironment(_ reason: String) {
        status = .deferred
        self.reason = reason
    }

    static func read(_ dir: URL) -> Self? {
        guard let object = SessionState.value(dir, key),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to dir: URL) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        try SessionState.amend(dir, with: [Self.key: object])
    }
}
