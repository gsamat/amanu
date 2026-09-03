import Foundation

/// Who is reporting, and whether they are reporting at all.
///
/// The identifier is a random UUID made on the first run and kept for ever.
/// That is a deliberate and expensive choice, argued in
/// `docs/specs/2026-08-22-analytics-design.md`: it buys funnels and
/// per-person counts without any of the machinery anonymous counters need,
/// and it costs a permanent handle on one machine's working habits.
///
/// It lives beside `setup.json` rather than in `config.json`, for the reason
/// `SetupState` gives: the config file holds decisions a person made, and a
/// UUID nobody chose is not one. The decision — the switch — does live in
/// `config.json`, so that a person who turns analytics off can see the line
/// that says so, and a person who leaves it on never gets a line at all.
///
/// Both files sit in `~/.config/amanu`, which makes "forget everything you
/// know about me, locally" a single `rm ~/.config/amanu/analytics*.json`.
enum AnalyticsIdentity {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/amanu/analytics.json")

    /// On unless the config file says otherwise. Opt-out is the whole reason
    /// the numbers are worth anything, and the whole reason the disclosure in
    /// `docs/analytics.md` and the visible switch have to be real.
    static func isEnabled(in json: [String: Any] = Config.raw()) -> Bool {
        json["analytics"] as? Bool ?? true
    }

    /// The identifier, made on first read and stable afterwards.
    ///
    /// A machine whose home directory cannot be written still gets one — it
    /// just gets a new one every launch, which reads as a stream of one-event
    /// installs. That is a wrong number rather than a crash, and analytics is
    /// never allowed to be the reason something fails.
    static func identifier(at url: URL = path) -> String {
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = json["id"] as? String, !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        let data = try? JSONSerialization.data(
            withJSONObject: ["id": fresh, "created_at": ISO8601DateFormatter().string(from: Date())],
            options: [.prettyPrinted, .sortedKeys])
        if let data {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return fresh
    }

    /// Whether an identifier has ever been written. This is what makes
    /// `installed` fire once: the first run is the run that had no file.
    static func isFirstRun(at url: URL = path) -> Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// Remember that this packaged version has announced itself. The return
    /// value is the event decision: true exactly once per version. Kept in the
    /// identity file so replacing the UUID also makes the installation a new
    /// release cohort, while preserving every other identity field.
    static func markVersionSeen(_ version: String, at url: URL = path) -> Bool {
        guard !version.isEmpty else { return false }
        var json = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0 } ?? [:]
        var seen = json["versions_seen"] as? [String] ?? []
        guard !seen.contains(version) else { return false }
        seen.append(version)
        json["versions_seen"] = seen
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
