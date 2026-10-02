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
        static let transcriptionDeferred = "transcription_deferred"
        static let transcriptionAttempts = "transcription_attempts"
        /// Optional per-session choice made from Recordings' Re-transcribe
        /// context menu. It survives another manual retry as the last choice.
        static let transcriptionEngine = "transcription_engine"
        /// `deferred` — every backend failed for a reason that will pass (no
        /// network, spent allowance): retry later. `failed: <reason>` — it
        /// won't work on a retry. Absent — nothing to do, either because the
        /// summary exists or because summarizing is off.
        static let summaryStatus = "summary_status"
        /// The same three states for putting names to the speaker labels.
        /// `deferred` — no model could be reached: retry later. `failed` — it
        /// won't work on a retry. Absent — nothing to do, either because
        /// `speakers.json` exists or because naming is off.
        static let speakersStatus = "speakers_status"
        /// Beside a `failed` status, what the configuration was when it
        /// failed — `MeetingEgress.fingerprint`. A `failed` step is offered
        /// again once the configuration no longer matches; one without a
        /// fingerprint, written before there were any, stays written off.
        static let summaryFailedFor = "summary_failed_for"
        static let speakersFailedFor = "speakers_failed_for"
        /// How many times each pass has been deferred after reaching a
        /// backend — see `ChainAttempt`.
        static let summaryDeferrals = "summary_deferrals"
        /// True while `summary.md` was written from a transcript that has
        /// since been discarded for a new one. The file is kept until a
        /// summary of the new transcript replaces it — a re-transcription
        /// that fails for good would otherwise have cost the only summary
        /// there was — and until then it is owed, and not shown as done.
        static let summaryStale = "summary_stale"
        static let speakersDeferrals = "speakers_deferrals"
    }

    static let failed = "failed"

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

    /// Why meta.json could not be amended.
    enum StateError: Error, CustomStringConvertible {
        case unreadable(URL)
        case unwritable(URL, Error)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't read \(url.path)"
            case .unwritable(let url, let error): return "can't write \(url.path): \(error)"
            }
        }
    }

    /// Merge fields into meta.json, leaving everything else alone. A value of
    /// `nil` removes its key — that's how a state that no longer applies gets
    /// cleared rather than lingering as a stale claim.
    ///
    /// The read and the write are one step under the session's lock, so two
    /// writers amending different keys both land; before, each wrote back the
    /// copy it had read, and the later one erased the earlier one's keys.
    static func amend(_ dir: URL, with fields: [String: Any?]) throws {
        let url = dir.appendingPathComponent("meta.json")
        try SessionLock.withLock(dir) {
            // A missing or unparsable meta.json is not recreated from the
            // fields alone: a file holding nothing but a status would read as
            // a session with no audio, and the recording's own record of
            // itself is worth more than the note being added to it.
            guard var json = read(dir) else { throw StateError.unreadable(url) }
            for (key, value) in fields {
                if let value { json[key] = value } else { json.removeValue(forKey: key) }
            }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch {
                throw StateError.unwritable(url, error)
            }
        }
    }

    /// `amend` for callers with nothing better to do about a failure than to
    /// say so. It used to be swallowed whole, which is how a status that could
    /// not be written looked exactly like a status that had been: the log is
    /// where somebody reading the session later will see it.
    @discardableResult
    static func update(_ dir: URL, with fields: [String: Any?]) -> Bool {
        do {
            try amend(dir, with: fields)
            return true
        } catch {
            appendSessionLog("couldn't record \(fields.keys.sorted().joined(separator: ", ")) "
                + "in meta.json: \(error)", to: dir)
            return false
        }
    }
}
