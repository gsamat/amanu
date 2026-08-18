import Foundation

/// Whether the first-run window has been through, and for which version of it.
///
/// It lives in its own file rather than in `config.json`, because the config
/// file holds decisions a person made and nothing else — that is what makes it
/// readable — and "the setup window has been seen" is not a decision.
///
/// The absence of a config file cannot stand in for this. Settings are only
/// written when they differ from their default, so a person who agreed with
/// every default has no config file and never will, and using that as the
/// first-run flag would show them the window at every launch for ever.
///
/// The stored version is what lets a later release ask for something new — a
/// permission, a choice — without dragging everyone through the whole window
/// again: raise `current`, and the window opens once more showing only what it
/// hasn't been told.
enum SetupState {
    /// Raise this when the window gains something a person must answer.
    static let current = 1

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/amanu/setup.json")

    /// The version of setup that has been completed, or nil for a machine that
    /// has never been through it.
    static func completedVersion(at stateURL: URL = path) -> Int? {
        guard
            let data = try? Data(contentsOf: stateURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? Int
    }

    static func isPending(at stateURL: URL = path) -> Bool {
        (completedVersion(at: stateURL) ?? 0) < current
    }

    static var isPending: Bool { isPending(at: path) }

    /// Record that the window has been through. Failure is not worth
    /// escalating: the cost is the window opening again, not a lost recording.
    static func markCompleted(at stateURL: URL = path) {
        let json: [String: Any] = [
            "version": current,
            "completed_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Forget, so the window opens again — what `amanu setup` does when it
    /// can't reach a running daemon to ask it politely.
    static func reset(at stateURL: URL = path) {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
