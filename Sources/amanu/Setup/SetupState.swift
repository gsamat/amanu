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
        write(["completed_at": ISO8601DateFormatter().string(from: Date())], at: stateURL)
    }

    /// Remember that a deliberate tone made the round trip through the
    /// system-audio tap.
    ///
    /// macOS has no API that reads this grant, so without a memory the window
    /// has to treat every opening as the first one and ask for the test again
    /// — including on a Mac that has been recording both sides of meetings all
    /// week. What is remembered is a measurement and it is shown as one, with
    /// the date it was taken, and the test is always one click away.
    static func rememberSystemAudioHeard(now: Date = Date(), at stateURL: URL = path) {
        write(["system_audio_heard_at": ISO8601DateFormatter().string(from: now)], at: stateURL)
    }

    static func systemAudioHeardAt(at stateURL: URL = path) -> Date? {
        guard
            let data = try? Data(contentsOf: stateURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let stamp = json["system_audio_heard_at"] as? String
        else { return nil }
        return ISO8601DateFormatter().date(from: stamp)
    }

    /// Merge into whatever is already on disk: the completion version and the
    /// last heard tone are written at different moments and neither should
    /// erase the other.
    private static func write(_ values: [String: Any], at stateURL: URL) {
        var json = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0 } ?? [:]
        json["version"] = current
        for (key, value) in values { json[key] = value }

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
