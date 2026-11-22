import Foundation

/// Puts real names to a transcript's speaker labels.
///
/// The recording side can say which *track* someone spoke on, and a diarizing
/// engine can say how many distinct voices there were, but neither knows who
/// anyone is. The meeting does: the calendar lists who was invited, and people
/// address each other by name out loud. This pass reads both and proposes a
/// mapping, which the session then keeps in `speakers.json`.
///
/// Two gates stand between the model's answer and the transcript, because a
/// wrong name is worse than no name — "them A" is merely unhelpful, while
/// "Фёдор" attributed to the wrong person is a transcript that lies:
///
/// 1. Only `high` confidence is applied. Anything less leaves the label alone.
/// 2. The quote the model offers as justification has to actually appear in
///    the transcript. A model that invents a name usually invents the line it
///    came from too, and that is cheap to check.
///
/// A name is not required to come from the attendee list: people join meetings
/// they weren't invited to, and being addressed by name is evidence wherever
/// it comes from.
enum SpeakerNamer {
    /// Room for the whole transcript in one call. Same size the summarizer
    /// uses; a backend with less room says so in `promptLimit`, and the
    /// transcript is trimmed to that instead.
    static let maxChars = 60_000
    /// A quote shorter than this proves nothing — "да" appears everywhere.
    private static let minQuoteWords = 2

    /// Resolve the speakers of a finished transcript and write `speakers.json`.
    ///
    /// Returns the names on success, nil when nothing was written. Either way
    /// the session's state records which kind of nothing it was, so a later
    /// pass can tell "come back to this" from "this will never work".
    @discardableResult
    static func name(
        transcript: Transcript,
        title: String?,
        attendees: [String],
        app: String?,
        into dir: URL
    ) async -> SpeakerNames? {
        func log(_ message: String) { appendSessionLog(message, to: dir) }

        // Where the transcript may go is an answer in the config file, and a
        // file broken since the job began is not one. Nothing is recorded,
        // so naming is still owed once the file reads again.
        if let reason = Config.unreadableReason {
            log("naming waits — config.json can't be read (\(reason))")
            return nil
        }
        let settings = Config.speakerNames()
        guard settings.enabled else { return nil }

        let labels = orderedLabels(of: transcript)
        guard !labels.isEmpty else {
            log("naming skipped — the transcript has no speakers")
            return nil
        }

        let existing = SpeakerNames.read(from: dir)
        var resolved = SpeakerNames(speakers: [:])

        // The person holding the machine needs no model: the mic track is
        // theirs by construction, and the account knows their name.
        if labels.contains("me"), let owner = ownerName() {
            resolved.speakers["me"] = owner
        }

        // Only ask about labels nobody has answered for yet. A re-run after a
        // corrected name shouldn't spend a call re-deriving what's settled.
        let known = Set(
            (existing?.speakers ?? [:]).filter { $0.value.name != nil }.keys
        ).union(resolved.speakers.keys)
        let asking = labels.filter { !known.contains($0) }

        guard !asking.isEmpty else {
            log("naming — every speaker already has a name")
            return finish(resolved, transcript: transcript, dir: dir, log: log)
        }

        // Where the transcript may go is not this pass's decision: naming
        // follows the summary unless it was given a backend of its own, and
        // with summaries off it asks nobody.
        guard let route = MeetingEgress.route(for: .speakerNames) else {
            log("naming — no model may read this meeting (summaries are off, or "
                + "speaker_names.backend is none), so only your own name is applied")
            return finish(resolved, transcript: transcript, dir: dir, log: log)
        }
        let backends = LLMBackend.available(
            preference: route.preference, anthropicModel: route.anthropicModel
        )
        if backends.isEmpty {
            log("naming — \(route.preference) is not available on this Mac")
        }
        // Deferred if any backend failed in a way that passes, for the same
        // reason as the summary: a bad answer from one reachable backend must
        // not write off the one that was merely offline.
        var attempt = ChainAttempt()
        var lastBackend = route.preference
        var lastModel: String?
        var lastReason = Analytics.Reason.unknown

        for backend in backends {
            do {
                log("naming speakers with \(backend.name)")
                let answer = try await backend.call(
                    systemPrompt,
                    prompt(
                        transcript: transcript,
                        labels: asking,
                        title: title,
                        attendees: attendees,
                        app: app,
                        limit: min(maxChars, backend.promptLimit ?? maxChars)
                    )
                )
                let proposals = try parse(answer)
                var fresh = resolved
                fresh.backend = backend.name
                fresh.model = backend.model
                for proposal in proposals where asking.contains(proposal.label) {
                    fresh.speakers[proposal.label] = accept(proposal, in: transcript, log: log)
                }
                // Labels the model skipped entirely still get an entry, so the
                // file records that they were considered and left unnamed.
                for label in asking where fresh.speakers[label] == nil {
                    fresh.speakers[label] = SpeakerNames.Entry(name: nil, source: .model)
                }

                let finished = finish(fresh, transcript: transcript, dir: dir, log: log)
                if let finished {
                    log("named \(finished.namedCount) of \(labels.count) speaker(s)")
                    Analytics.track(.speakerNamesFinished, [
                        .backend: .text(backend.name),
                        .model: .text(AnalyticsCatalogue.summaryModel(
                            backend: backend.name, model: backend.model)),
                    ])
                }
                return finished
            } catch {
                attempt.note(error, from: backend)
                lastBackend = backend.name
                lastModel = backend.model
                lastReason = Analytics.reason(for: error)
                log(LLMError.isUsageLimit(error)
                    ? "\(backend.name) is out of allowance — trying the next backend"
                    : "naming via \(backend.name) failed: \(error)")
            }
        }

        let previous = SessionState.value(dir, SessionState.Key.speakersDeferrals) as? Int ?? 0
        let verdict = attempt.verdict(after: previous)
        SessionState.update(dir, with: ChainAttempt.fields(
            for: verdict, previous: previous,
            statusKey: SessionState.Key.speakersStatus,
            fingerprintKey: SessionState.Key.speakersFailedFor,
            countKey: SessionState.Key.speakersDeferrals,
            fingerprint: MeetingEgress.fingerprint(for: .speakerNames)))
        let deferred: Bool
        switch verdict {
        case .deferred:
            deferred = true
            log("no backend answered, and at least one could not be reached — naming deferred, "
                + "will be retried later")
        case .gaveUp(let deferrals?):
            deferred = false
            log("no backend has answered in \(deferrals) tries — giving up on speaker names "
                + "until the naming settings, keys or backends change")
        case .gaveUp(nil):
            deferred = false
            log("every backend failed for good — giving up on speaker names until the "
                + "naming settings, keys or backends change")
        }
        Analytics.track(.speakerNamesFailed, [
            .backend: .text(lastBackend),
            .model: .text(AnalyticsCatalogue.summaryModel(
                backend: lastBackend, model: lastModel)),
            .reason: .text(lastReason.rawValue),
            .outcome: .text((deferred ? Analytics.Outcome.deferred : .gaveUp).rawValue),
        ])
        return nil
    }

    /// Merge a pass into whatever `speakers.json` says now, write it,
    /// re-render the markdown against it, and clear the session's pending
    /// state. Naming is the only thing that rewrites `transcript.md`, and it
    /// never touches `transcript.json`.
    ///
    /// The file is read again here, under the session's lock, rather than
    /// merged into the copy read before the model was asked: a person can
    /// name a speaker in the recordings window during the minutes the model
    /// takes, and merging into the older copy wrote their name away.
    private static func finish(
        _ fresh: SpeakerNames,
        transcript: Transcript,
        dir: URL,
        log: (String) -> Void
    ) -> SpeakerNames? {
        do {
            return try SessionLock.withLock(dir) {
                let current = SpeakerNames.read(from: dir)
                let merged = current?.merged(with: fresh) ?? fresh
                try merged.write(to: dir)
                try transcript.writeMarkdown(to: dir, names: merged)
                SessionState.update(dir, with: [
                    SessionState.Key.speakersStatus: nil,
                    SessionState.Key.speakersFailedFor: nil,
                    SessionState.Key.speakersDeferrals: nil,
                ])
                return merged
            }
        } catch {
            // The transcript is intact either way — this only costs the names.
            log("couldn't write speaker names: \(error)")
            SessionState.update(dir, with: [
                SessionState.Key.speakersStatus: "failed",
            ])
            return nil
        }
    }

    // MARK: - the owner

    /// The person doing the recording, for the "me" track.
    static func ownerName() -> SpeakerNames.Entry? {
        if let configured = Config.userName() {
            return SpeakerNames.Entry(name: configured, source: .config)
        }
        if let account = personName(full: NSFullUserName(), login: NSUserName()) {
            return SpeakerNames.Entry(name: account, source: .account)
        }
        return nil
    }

    /// The account's full name, but only when it reads as a person's name.
    ///
    /// macOS will hand back whatever is in the account record, which is often
    /// not a name at all: the short login again, a device name left over from
    /// setup ("Samat's MacBook"), or a placeholder like "User". Printing any of
    /// those into a transcript as a speaker is worse than leaving "me", so the
    /// bar is deliberately high — two or more letter-only words that aren't
    /// the login and don't look like hardware.
    static func personName(full: String, login: String) -> String? {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(login) != .orderedSame
        else { return nil }

        let lower = trimmed.lowercased()
        let deviceish = ["macbook", "imac", "mac mini", "mac pro", "iphone", "ipad", "'s", "’s"]
        guard !deviceish.contains(where: { lower.contains($0) }) else { return nil }

        let placeholders = [
            "user", "administrator", "admin", "owner", "guest", "me",
            "пользователь", "админ", "гость",
        ]
        guard !placeholders.contains(lower) else { return nil }

        let words = trimmed.split(separator: " ")
        guard words.count >= 2 else { return nil }
        let nameish = words.allSatisfy { word in
            word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "." }
        }
        return nameish ? trimmed : nil
    }

    // MARK: - the model's answer

    struct Proposal: Decodable {
        let label: String
        let name: String?
        let confidence: String?
        let quote: String?
        let at_ms: Int?

        private enum CodingKeys: String, CodingKey {
            case label, name, confidence, quote, at_ms
        }

        /// Lenient about everything the gates don't depend on. Models hand
        /// back `"at_ms": "194000"` or `194000.0` about as often as the
        /// number asked for, and a strict decoder threw the whole mapping
        /// away over the one field nothing checks — every name in it, however
        /// well quoted, lost to the type of a timestamp.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            confidence = try? container.decodeIfPresent(String.self, forKey: .confidence)
            quote = try? container.decodeIfPresent(String.self, forKey: .quote)
            // Bounded before converting: `Int(_:)` traps on a double out of
            // range, and a model can write any number it likes.
            func milliseconds(_ number: Double?) -> Int? {
                guard let number, number.isFinite, number.magnitude < 1e12 else { return nil }
                return Int(number)
            }
            at_ms = milliseconds(try? container.decodeIfPresent(Double.self, forKey: .at_ms))
                ?? milliseconds((try? container.decodeIfPresent(String.self, forKey: .at_ms))
                    .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        }
    }

    /// Apply the two gates. Anything that doesn't clear both becomes an entry
    /// with no name, which prints as the original label.
    static func accept(
        _ proposal: Proposal,
        in transcript: Transcript,
        log: (String) -> Void = { _ in }
    ) -> SpeakerNames.Entry {
        let unnamed = SpeakerNames.Entry(
            name: nil, source: .model, confidence: proposal.confidence
        )
        guard let name = proposal.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return unnamed }

        guard proposal.confidence?.lowercased() == "high" else {
            log("\(proposal.label): \"\(name)\" not confident enough "
                + "(\(proposal.confidence ?? "unstated")) — leaving the label")
            return unnamed
        }
        guard let quote = proposal.quote, quoteAppears(quote, in: transcript) else {
            log("\(proposal.label): \"\(name)\" dropped — its supporting quote "
                + "isn't in the transcript")
            return unnamed
        }
        return SpeakerNames.Entry(
            name: name,
            source: .model,
            confidence: proposal.confidence,
            quote: quote,
            at_ms: proposal.at_ms
        )
    }

    /// Whether a quote really was said. Compared on words rather than
    /// characters so punctuation and capitalization don't decide it, and
    /// deliberately not restricted to ASCII — the meetings this runs on are
    /// mostly Russian.
    static func quoteAppears(_ quote: String, in transcript: Transcript) -> Bool {
        let needle = words(quote)
        guard needle.count >= minQuoteWords else { return false }
        let haystack = transcript.segments.flatMap { words($0.text) }
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "'" || $0.isWhitespace }
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Pull the JSON object out of whatever the model wrapped it in — code
    /// fences, a sentence of preamble, both.
    static func parse(_ answer: String) throws -> [Proposal] {
        guard
            let start = answer.firstIndex(of: "{"),
            let end = answer.lastIndex(of: "}"),
            start < end
        else { throw LLMError.malformedResponse("no JSON object in the answer") }

        struct Answer: Decodable { let speakers: [Proposal] }
        let json = Data(answer[start...end].utf8)
        guard let decoded = try? JSONDecoder().decode(Answer.self, from: json) else {
            throw LLMError.malformedResponse("couldn't decode the speaker mapping")
        }
        return decoded.speakers
    }

    // MARK: - prompting

    private static let systemPrompt = """
    You are identifying who spoke in a meeting transcript.

    The transcript is machine-made: it has recognition errors, and its speaker \
    labels are mechanical — "me" is the person who recorded the meeting, "them" \
    is the far end, and letter suffixes distinguish voices the recognizer told \
    apart. Your job is to work out which real person each label is.

    Evidence is what people say: someone addressed by name, someone introducing \
    themselves, someone referred to in the third person and then answering. The \
    invitee list helps, but do not assume the people present are the people \
    invited, and do not assume they are in any particular order.

    Answer only for labels you were asked about. Say "high" confidence only when \
    the transcript itself shows the answer — if you are reasoning from who was \
    invited rather than from what was said, that is "medium" at best. Leaving a \
    speaker unidentified is a good outcome; guessing is not.
    """

    private static let instructions = """
    Reply with JSON and nothing else, in this shape:

    {"speakers": [
      {"label": "them A", "name": "Фёдор", "confidence": "high",
       "quote": "Фёдор, что там с договором?", "at_ms": 194000}
    ]}

    One entry per label you were asked about. Use null for `name` when you \
    cannot tell. `quote` must be copied word for word from the transcript — it \
    is checked against the text, and an entry whose quote cannot be found is \
    discarded. `at_ms` is the timestamp of the line you quoted.
    """

    static func prompt(
        transcript: Transcript,
        labels: [String],
        title: String?,
        attendees: [String],
        app: String?,
        limit: Int = maxChars
    ) -> String {
        var header: [String] = []
        if let title { header.append("Meeting: \(title)") }
        if !attendees.isEmpty {
            header.append("Invited: " + attendees.joined(separator: ", "))
        }
        if let app { header.append("Recorded from: \(app)") }
        header.append("Identify these labels: " + labels.joined(separator: ", "))

        return """
        \(header.joined(separator: "\n"))

        \(instructions)

        ---
        \(body(of: transcript, attendees: attendees, limit: limit))
        """
    }

    /// The transcript as the namer sees it — timestamped, so a quote can be
    /// located — trimmed to fit if the meeting was long.
    ///
    /// Trimming keeps the opening and the close rather than a uniform sample,
    /// and adds every line that mentions an invitee: those are where names are
    /// actually said. A middle hour of a design argument contains no evidence
    /// about who anyone is.
    ///
    /// Two fifths of `limit` go to the opening, where names cluster because
    /// people greet each other and introduce themselves, a tenth to the
    /// close, where they say goodbye by name, and what is left to the
    /// mentions — so the whole never exceeds `limit`, which a small local
    /// model with a fixed context would otherwise have cut from the front.
    static func body(
        of transcript: Transcript, attendees: [String], limit: Int = maxChars
    ) -> String {
        let lines = transcript.segments.map {
            "[\($0.start_ms)] \($0.speaker): \($0.text)"
        }
        let whole = lines.joined(separator: "\n")
        guard whole.count > limit else { return whole }
        let openingChars = limit * 2 / 5
        let closingChars = limit / 10

        var opening: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > openingChars { break }
            opening.append(line)
            size += line.count + 1
        }

        var closing: [String] = []
        size = 0
        for line in lines.reversed() {
            if size + line.count > closingChars { break }
            closing.insert(line, at: 0)
            size += line.count + 1
        }

        let firstNames = attendees.flatMap { $0.split(separator: " ").map(String.init) }
            .filter { $0.count > 2 }
            .map { $0.lowercased() }
        let mentions = lines.dropFirst(opening.count).dropLast(closing.count).filter { line in
            let lower = line.lowercased()
            return firstNames.contains { lower.contains($0) }
        }

        var parts = [opening.joined(separator: "\n")]
        // What the opening and the close left, less room for the two markers.
        var room = limit - openingChars - closingChars - 120
        var kept: [String] = []
        for line in mentions.prefix(200) {
            if line.count + 1 > room { break }
            kept.append(line)
            room -= line.count + 1
        }
        if !kept.isEmpty {
            parts.append("[… middle of the meeting, lines mentioning invitees …]")
            parts.append(kept.joined(separator: "\n"))
        }
        parts.append("[… end of the meeting …]")
        parts.append(closing.joined(separator: "\n"))
        return parts.joined(separator: "\n")
    }

    /// Speaker labels in the order they first appear, so prompts and files
    /// read in the order the meeting happened rather than alphabetically.
    static func orderedLabels(of transcript: Transcript) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for segment in transcript.segments where !SpeakerNames.isUnknown(segment.speaker)
            && !seen.contains(segment.speaker) {
            seen.insert(segment.speaker)
            out.append(segment.speaker)
        }
        return out
    }
}
