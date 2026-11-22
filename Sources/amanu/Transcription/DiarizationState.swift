import Foundation

/// The requested local stage lives in meta.json so an existing transcript cannot
/// accidentally make an unfinished recording look complete after a restart.
struct DiarizationState: Codable, Equatable {
    enum Persisted {
        case absent
        case valid(DiarizationState)
        case unreadable

        var retainsAudio: Bool {
            switch self {
            case .absent: false
            case .valid(let state): state.retainsAudio
            case .unreadable: true
            }
        }

        var isFinal: Bool { !retainsAudio }
        var keepsCandidateText: Bool {
            switch self {
            case .absent: false
            case .valid(let state): state.isOutstanding
            case .unreadable: true
            }
        }
        var isUnreadable: Bool {
            if case .unreadable = self { return true }
            return false
        }
    }

    enum Status: String, Codable {
        case pending, running, deferred, failed, completed, partial, skipped
        case notApplicable = "not_applicable"
    }

    struct Request: Codable, Equatable {
        let engine: String
        let threshold: Double
        let explicit: Bool
        let model: DiarizationModel

        init(engine: String, threshold: Double, explicit: Bool = false,
             model: DiarizationModel = .default) {
            self.engine = engine
            self.threshold = threshold
            self.explicit = explicit
            self.model = model
        }

        private enum CodingKeys: String, CodingKey { case engine, threshold, explicit, model }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(engine: try values.decode(String.self, forKey: .engine),
                      threshold: try values.decode(Double.self, forKey: .threshold),
                      explicit: try values.decodeIfPresent(Bool.self, forKey: .explicit) ?? false,
                      model: try values.decodeIfPresent(DiarizationModel.self, forKey: .model) ?? .community1)
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

    /// Absence and an unreadable saved request have different safety rules.
    /// An unknown future model must not be reinterpreted as Community-1.
    static func persisted(in dir: URL) -> Persisted {
        guard let meta = SessionState.read(dir) else { return .unreadable }
        guard let object = meta[key] else { return .absent }
        guard
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return .unreadable }
        guard let state = try? JSONDecoder().decode(Self.self, from: data)
        else { return .unreadable }
        return .valid(state)
    }

    static func read(_ dir: URL) -> Self? {
        if case .valid(let state) = persisted(in: dir) { return state }
        return nil
    }

    func write(to dir: URL) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))
        try SessionState.amend(dir, with: [Self.key: object])
    }
}
