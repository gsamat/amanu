import Foundation

/// Turns a finished transcript into `summary.md`.
///
/// The backend chain lives in LLMBackend: subscription CLIs first, then API
/// keys, then ollama. Which of them may read the meeting is `MeetingEgress`'s
/// to say; summarizing is just one caller of it.
///
/// Nothing here is allowed to fail loudly. A missing summary is an
/// inconvenience; a transcript lost because summarizing threw is a lost
/// meeting. Every path logs and returns.
enum Summarizer {
    /// Above this, the transcript is summarized in pieces and the pieces are
    /// summarized together. Comfortably inside every backend's context window,
    /// including a small local model's.
    private static let maxCharsPerCall = 60_000

    /// Write summary.md for a finished session. Returns the backend that
    /// produced it, or nil if summarization is off or every backend failed.
    @discardableResult
    static func summarize(
        transcript: Transcript,
        context: [String],
        into dir: URL,
        speakerNamesRevision: Int? = nil
    ) async -> String? {
        func log(_ message: String) { appendSessionLog(message, to: dir) }

        // Checked here and not only where the job began: naming can take
        // minutes, and the route below is read from the file as it is now.
        // Nothing is recorded, so the summary is still owed once the file
        // reads again.
        if let reason = Config.unreadableReason {
            log("summary waits — config.json can't be read (\(reason))")
            return nil
        }
        let settings = Config.summary()
        let namesRevision = speakerNamesRevision
            ?? (SessionState.value(dir, SessionState.Key.speakerNamesRevision) as? Int ?? 0)
        let transcriptRevision = SpeakerReview.transcriptID(dir)
        guard MeetingEgress.route(for: .summary) != nil else { return nil }

        let body = plainText(transcript)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("summary skipped — the transcript is empty")
            return nil
        }

        let backends = MeetingEgress.backends(for: .summary)
        guard !backends.isEmpty else {
            log("summary skipped — no backend available")
            Analytics.track(.summaryFailed, [
                .backend: .text(settings.backend),
                .reason: .text(Analytics.Reason.noKey.rawValue),
                .outcome: .text(Analytics.Outcome.deferred.rawValue),
            ])
            return nil
        }
        // Whether any backend failed in a way that passes. If one did, the
        // session is left marked for a later run rather than written off: a
        // meeting summarized on a plane should still get its summary that
        // evening, even if a backend that was reachable answered badly — the
        // one that wasn't may well answer. Only when every backend failed for
        // good, or the later runs have run out, is the summary given up on.
        var attempt = ChainAttempt()
        var lastReason = Analytics.Reason.unknown

        // Whatever we know about the meeting, above the transcript. Names in
        // particular: given a participant list, the summarizer writes "Anna
        // will send the contract" instead of "them will send the contract".
        let header = context.isEmpty ? "" : context.joined(separator: "\n") + "\n"
        for backend in backends {
            do {
                log("summarizing with \(backend.name)")
                let markdown = try await produce(
                    body: body, header: header, settings: settings, backend: backend
                )
                let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw LLMError.emptyResponse(backend.name) }
                let saved = try SessionLock.withLock(dir) {
                    guard (SessionState.value(dir, SessionState.Key.speakerNamesRevision) as? Int ?? 0) == namesRevision,
                          SpeakerReview.transcriptID(dir) == transcriptRevision else {
                        try SessionState.amend(dir, with: [
                            SessionState.Key.summaryStale: true,
                            SessionState.Key.summaryManualUpdate: true,
                            SessionState.Key.summaryUpdateRequested: nil,
                        ])
                        return false
                    }
                    try Data((text + "\n").utf8).write(
                        to: dir.appendingPathComponent("summary.md"), options: .atomic)
                    try SessionState.amend(dir, with: [
                        SessionState.Key.summaryStatus: nil,
                        SessionState.Key.summaryFailedFor: nil,
                        SessionState.Key.summaryDeferrals: nil,
                        SessionState.Key.summaryStale: nil,
                        SessionState.Key.summaryManualUpdate: nil,
                        SessionState.Key.summaryUpdateRequested: nil,
                    ])
                    return true
                }
                guard saved else {
                    log("summary result discarded — transcript or speaker names changed during generation")
                    return nil
                }
                log("summary written by \(backend.name)")
                Analytics.track(.summaryFinished, [
                    .backend: .text(backend.name),
                    .model: .text(AnalyticsCatalogue.summaryModel(
                        backend: backend.name, model: backend.model)),
                ])
                return backend.name
            } catch {
                // Falling through is the expected path when a subscription is
                // spent, so say which kind of failure this was — otherwise a
                // healthy hand-off reads like something broke.
                attempt.note(error, from: backend)
                lastReason = Analytics.reason(for: error)
                Analytics.track(.summaryBackendFailed, [
                    .backend: .text(backend.name),
                    .model: .text(AnalyticsCatalogue.summaryModel(
                        backend: backend.name, model: backend.model)),
                    .reason: .text(lastReason.rawValue),
                ])
                log(LLMError.isUsageLimit(error)
                    ? "\(backend.name) is out of allowance — trying the next backend"
                    : "summary via \(backend.name) failed: \(error)")
            }
        }

        // Nothing answered. Record which kind of nothing, so a later pass can
        // tell "come back to this" from "this will never work".
        let previous = SessionState.value(dir, SessionState.Key.summaryDeferrals) as? Int ?? 0
        let verdict = attempt.verdict(after: previous)
        SessionState.update(dir, with: ChainAttempt.fields(
            for: verdict, previous: previous,
            statusKey: SessionState.Key.summaryStatus,
            fingerprintKey: SessionState.Key.summaryFailedFor,
            countKey: SessionState.Key.summaryDeferrals,
            fingerprint: MeetingEgress.fingerprint(for: .summary)))
        let deferred: Bool
        switch verdict {
        case .deferred:
            deferred = true
            log("no backend answered, and at least one could not be reached — summary deferred, "
                + "will be retried later")
        case .gaveUp(let deferrals?):
            deferred = false
            log("no backend has answered in \(deferrals) tries — giving up on the summary until "
                + "the summary settings, keys or backends change")
        case .gaveUp(nil):
            deferred = false
            log("every backend failed for good — giving up on the summary until the "
                + "summary settings, keys or backends change")
        }
        Analytics.track(.summaryFailed, [
            .backend: .text(settings.backend),
            .reason: .text(lastReason.rawValue),
            .outcome: .text((deferred ? Analytics.Outcome.deferred : .gaveUp).rawValue),
        ])
        return nil
    }

    // MARK: - prompting

    private static func systemPrompt(language: String?) -> String {
        let target = language.map { "Write the note in \($0)." }
            ?? "Write the note in the same language the meeting was held in."
        return """
        You are taking notes on a meeting from its transcript.
        \(target) Translate the section headings into that language too.
        Invent nothing that isn't in the transcript. If something never came up, say so.
        The transcript is machine-made and contains recognition errors — read past odd \
        words rather than treating them as meaningful.
        Speakers are labelled "me" (the person recording) and "them" (everyone else).
        """
    }

    private static let chunkInstructions = """
    Below is one part of a long meeting transcript. Write a compact set of notes on it:
    what was discussed, what was decided, which tasks and questions came up.
    Facts from this part only, no preamble.
    """

    private static let mergeInstructions = """
    Below are consecutive notes on parts of a single meeting. Combine them into one note.
    """

    private static func produce(
        body: String,
        header: String,
        settings: Config.SummarySettings,
        backend: LLMBackend
    ) async throws -> String {
        let system = systemPrompt(language: settings.language)
        let limit = min(maxCharsPerCall, backend.promptLimit ?? maxCharsPerCall)
        if body.count <= limit {
            return try await backend.call(system, singlePassPrompt(
                body: body, header: header, template: settings.template))
        }

        let chunks = split(body, limit: limit)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            notes.append(try await backend.call(
                system,
                "\(header)Part \(index + 1) of \(chunks.count).\n\(chunkInstructions)\n\n---\n\(chunk)"
            ))
        }
        return try await backend.call(
            system,
            "\(header)\n\(mergeInstructions)\n\(settings.template)\n\n---\n"
                + notes.joined(separator: "\n\n---\n\n")
        )
    }

    /// The whole user-visible instruction for an ordinary meeting. Kept as a
    /// pure function so a custom template can be proven to replace, rather
    /// than accidentally sit beside, the built-in one.
    static func singlePassPrompt(body: String, header: String, template: String) -> String {
        "\(header)\n\(template)\n\n---\n\(body)"
    }

    /// The transcript as the summarizer sees it: one speaker-tagged line per
    /// segment, timestamps dropped — they cost tokens and add nothing to a
    /// summary.
    private static func plainText(_ transcript: Transcript) -> String {
        transcript.segments
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Split on line boundaries so a chunk never ends mid-sentence.
    private static func split(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if size + line.count > limit && !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(String(line))
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

}
