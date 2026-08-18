import Foundation

/// `meta.json` is the session's state file — what was recorded, how it ended,
/// what has been done to it since. Several parts of the program read and amend
/// it (the transcription queue, the summarizer, the compressor), so the
/// read-modify-write lives in one place rather than three.
enum SessionState {
    /// Keys that describe what still needs doing to a session. A post-run pass
    /// reads these to decide what to pick up.
    enum Key {
        /// Present when a session was retired without a transcript.
        static let transcriptionFailed = "transcription_failed"
        static let transcriptionAttempts = "transcription_attempts"
        /// `deferred` — every backend failed for a reason that will pass (no
        /// network, spent allowance): retry later. `failed: <reason>` — it
        /// won't work on a retry. Absent — nothing to do, either because the
        /// summary exists or because summarizing is off.
        static let summaryStatus = "summary_status"
    }

    static let deferred = "deferred"

    static func read(_ dir: URL) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func value(_ dir: URL, _ key: String) -> Any? {
        read(dir)?[key]
    }

    /// Merge fields into meta.json, leaving everything else alone. A value of
    /// `nil` removes its key — that's how a state that no longer applies gets
    /// cleared rather than lingering as a stale claim.
    static func update(_ dir: URL, with fields: [String: Any?]) {
        let url = dir.appendingPathComponent("meta.json")
        guard var json = read(dir) else { return }
        for (key, value) in fields {
            if let value { json[key] = value } else { json.removeValue(forKey: key) }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
