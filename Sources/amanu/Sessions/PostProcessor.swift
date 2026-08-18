import Foundation

/// Everything that happens to a session after its transcript exists: putting
/// names to the speakers, then summarizing.
///
/// Both steps need a language model, which is exactly what a laptop on a train
/// doesn't have, so both have to be able to not happen and be picked up later.
/// The session records which — `deferred` for a machine that was offline,
/// `failed` for work that won't succeed on a retry — and this type is what
/// comes back for the first kind.
///
/// It runs in two situations that used to be different code: immediately after
/// a transcript is written, and later, when something suggests the answer may
/// have changed (a launch, the network returning, a person pressing a button).
/// Making them the same path is what fixes the older bug where a summary
/// skipped offline was dropped for ever — nothing ever went back for it.
enum PostProcessor {
    /// Which optional post-processing steps this invocation should consider.
    /// Production reads it from Config; tests can name the policy they are
    /// exercising without borrowing the machine owner's current preferences.
    struct Policy: Equatable {
        var names: Bool
        var summary: Bool

        static var configured: Policy {
            let summary = Config.summary()
            return Policy(
                names: Config.speakerNames().enabled,
                summary: summary.enabled && summary.backend != "none")
        }
    }

    /// Steps outstanding for one session, in the order they must run.
    struct Work: Equatable {
        var names = false
        var summary = false
        var isEmpty: Bool { !names && !summary }
    }

    /// What still needs doing, reading the session's own record of itself.
    ///
    /// A step is outstanding when its artifact is missing and its state isn't
    /// `failed` — a session that will never summarize must stop being offered,
    /// or every sweep picks it up again for ever.
    static func outstanding(_ dir: URL, policy: Policy = .configured) -> Work {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        func gaveUp(_ key: String) -> Bool {
            guard let status = SessionState.value(dir, key) as? String else { return false }
            return status != SessionState.deferred
        }

        guard exists("transcript.json") else { return Work() }

        var work = Work()
        work.names = policy.names
            && !exists(SpeakerNames.file)
            && !gaveUp(SessionState.Key.speakersStatus)
        work.summary = policy.summary
            && !exists("summary.md")
            && !gaveUp(SessionState.Key.summaryStatus)
        return work
    }

    /// Run whatever is outstanding for one session. Returns what it did.
    ///
    /// Order matters and is the whole point: names first, so the summary is
    /// handed "Фёдор" instead of "them" and writes about people rather than
    /// about channels.
    @discardableResult
    static func finish(_ dir: URL) async -> Work {
        let work = outstanding(dir)
        guard !work.isEmpty else { return work }
        guard let transcript = readTranscript(dir) else {
            appendSessionLog("post-processing skipped — can't read transcript.json", to: dir)
            return Work()
        }

        let meta = SessionState.read(dir) ?? [:]
        let calendar = meta["calendar"] as? [String: Any]
        let title = (meta["title"] as? String) ?? (calendar?["title"] as? String)
        let attendees = calendar?["attendees"] as? [String] ?? []
        let app = meta["app"] as? String

        var names = SpeakerNames.read(from: dir)
        if work.names {
            names = await SpeakerNamer.name(
                transcript: transcript,
                title: title,
                attendees: attendees,
                app: app,
                into: dir
            ) ?? names
        }

        if work.summary {
            var context = ["Meeting: \(title ?? dir.lastPathComponent)"]
            if !attendees.isEmpty {
                context.append("Participants: " + attendees.joined(separator: ", "))
            }
            if let app { context.append("Recorded from: \(app)") }
            // The summarizer reads speaker labels straight off the segments,
            // so hand it a renamed copy rather than a note about the names.
            await Summarizer.summarize(
                transcript: transcript.named(with: names), context: context, into: dir
            )
        }

        return work
    }

    /// Walk the recordings root and finish everything that can be finished.
    ///
    /// Oldest first — folder names sort chronologically — so a backlog comes
    /// back in the order it happened. Sessions are handled one at a time on
    /// purpose: this competes with transcription for the same machine, and a
    /// backlog is never urgent.
    @discardableResult
    static func sweep(root: URL) async -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return 0 }

        var finished = 0
        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("meta.json").path
            ) else { continue }
            let work = await finish(dir)
            if !work.isEmpty { finished += 1 }
        }
        return finished
    }

    /// Offer a session to the transcription queue again.
    ///
    /// Clears the marks that retired it and removes the derived files, so the
    /// queue treats it as untranscribed at the next scan. The AssemblyAI
    /// response cache is deliberately kept: re-rendering from it is free,
    /// while re-uploading is neither free nor fast.
    static func markForRetranscription(_ dir: URL) {
        let fm = FileManager.default
        for file in ["transcript.json", "transcript.md", SpeakerNames.file] {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
        }
        SessionState.update(dir, with: [
            SessionState.Key.transcriptionFailed: nil,
            SessionState.Key.transcriptionAttempts: nil,
            SessionState.Key.speakersStatus: nil,
            SessionState.Key.summaryStatus: nil,
        ])
        appendSessionLog("queued for re-transcription", to: dir)
    }

    /// Put a name to a label by hand, and re-render the transcript against it.
    ///
    /// Recorded as `manual`, which is what protects it: a later naming run
    /// merges around it rather than over it. Someone who corrected a name once
    /// shouldn't have to notice it was quietly undone.
    ///
    /// An empty name clears the entry back to unnamed, so a correction can be
    /// taken back as easily as it was made.
    static func rename(_ label: String, to name: String?, in dir: URL) {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = SpeakerNames.read(from: dir) ?? SpeakerNames()
        names.speakers[label] = SpeakerNames.Entry(
            name: (cleaned?.isEmpty ?? true) ? nil : cleaned,
            source: .manual
        )
        do {
            try names.write(to: dir)
            if let transcript = readTranscript(dir) {
                try transcript.writeMarkdown(to: dir, names: names)
            }
            // The label now has an answer, so the session is no longer waiting
            // on a model for it.
            SessionState.update(dir, with: [SessionState.Key.speakersStatus: nil])
            appendSessionLog(
                cleaned?.isEmpty == false
                    ? "\(label) named \"\(cleaned!)\" by hand"
                    : "\(label) cleared by hand",
                to: dir
            )
        } catch {
            appendSessionLog("couldn't save the name for \(label): \(error)", to: dir)
        }
    }

    static func readTranscript(_ dir: URL) -> Transcript? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")),
            let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { return nil }
        return transcript
    }
}
