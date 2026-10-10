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

        /// Naming stays on whenever it is enabled, even with nowhere to send
        /// the transcript: the person recording is named from the account,
        /// which needs no model. The summary is on only when `MeetingEgress`
        /// has somewhere it may go.
        static var configured: Policy {
            Policy(
                names: Config.speakerNames().enabled,
                summary: MeetingEgress.route(for: .summary) != nil)
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
    /// A step is outstanding when its artifact is missing and it has not
    /// failed for good under the configuration in force now. A session that
    /// will never summarize must stop being offered, or every sweep picks it
    /// up again for ever — but "never" is only true of the settings, keys and
    /// backends it failed with, so a `failed` step whose recorded fingerprint
    /// no longer matches `MeetingEgress.fingerprint` is offered once more. A
    /// `failed` with no fingerprint predates the rule and stays given up.
    static func outstanding(_ dir: URL, policy: Policy = .configured) -> Work {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        let meta = SessionState.read(dir) ?? [:]
        func gaveUp(_ statusKey: String, _ fingerprintKey: String,
                    _ purpose: MeetingEgress.Purpose) -> Bool {
            guard let status = meta[statusKey] as? String,
                  status != SessionState.deferred
            else { return false }
            guard let failedFor = meta[fingerprintKey] as? String else { return true }
            return failedFor == MeetingEgress.fingerprint(for: purpose)
        }

        guard exists("transcript.json"), !TranscriptVersions.isRequested(dir),
              DiarizationState.persisted(in: dir).isFinal
        else { return Work() }

        var work = Work()
        work.names = policy.names
            && !exists(SpeakerNames.file)
            && !gaveUp(SessionState.Key.speakersStatus, SessionState.Key.speakersFailedFor,
                       .speakerNames)
        work.summary = policy.summary
            && !hasCurrentSummary(dir, meta: meta)
            && !gaveUp(SessionState.Key.summaryStatus, SessionState.Key.summaryFailedFor,
                       .summary)
        return work
    }

    /// Whether `summary.md` is there and was written from the transcript
    /// that is there now.
    static func hasCurrentSummary(_ dir: URL, meta: [String: Any]? = nil) -> Bool {
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("summary.md").path)
        else { return false }
        let meta = meta ?? SessionState.read(dir) ?? [:]
        return meta[SessionState.Key.summaryStale] as? Bool != true
    }

    /// Run whatever is outstanding for one session. Returns what it did.
    ///
    /// Order matters and is the whole point: names first, so the summary is
    /// handed "Фёдор" instead of "them" and writes about people rather than
    /// about channels.
    ///
    /// Four things call this — the transcription coordinator, the sweep at
    /// launch and on every network return, the recordings window's button, and
    /// `amanu process` — and any two of them can be in the same folder at the
    /// same moment. So it takes the session's claim first, and returns an empty
    /// `Work` when somebody else has it: these are model calls, and asking the
    /// same model the same question twice costs money for one answer.
    ///
    /// `policy` is here for the same reason `outstanding` has one: a test can
    /// say which steps it is exercising instead of inheriting whatever the
    /// machine owner has turned on this week.
    @discardableResult
    static func finish(_ dir: URL, policy: Policy = .configured) async -> Work {
        // Both steps hand the transcript to a model chosen by the config, so
        // they wait while it cannot be read — see `Config.Unreadable`.
        if let reason = Config.unreadableReason {
            appendSessionLog(
                "post-processing waits — config.json can't be read (\(reason))", to: dir)
            return Work()
        }
        let work = outstanding(dir, policy: policy)
        guard !work.isEmpty else { return work }

        do {
            try SessionClaim.acquire(dir, stage: .finish)
        } catch {
            appendSessionLog("post-processing skipped — \(error)", to: dir)
            return Work()
        }
        defer { SessionClaim.release(dir) }

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
        guard Config.unreadableReason == nil else { return 0 }

        var finished = 0
        for dir in SessionInventory.sessionFolders(in: root) {
            let work = await finish(dir)
            if !work.isEmpty { finished += 1 }
            StopHook.fireIfOwed(dir)
        }
        return finished
    }

    // MARK: - transcribing again

    /// Why a session cannot be transcribed from what is still in its folder,
    /// or nil when it can.
    ///
    /// Both surfaces that offer the work ask this one question — the
    /// recordings window to decide whether its button does anything, `amanu
    /// process` to print a sentence instead of shrugging — so the two can't
    /// reach different conclusions about the same folder.
    enum Obstacle: Equatable, CustomStringConvertible {
        case unreadable
        /// Transcribed once, then the audio was thrown away on purpose.
        case audioDiscarded
        /// Gone some other way: moved, or cleaned out with the Finder.
        case audioGone

        /// For the terminal, which stays English along with the rest of the
        /// command line.
        var description: String {
            switch self {
            case .unreadable:
                return "its meta.json can't be read"
            case .audioDiscarded:
                return "its audio was discarded after transcribing — keep_audio is off, "
                    + "so the transcript is all there is"
            case .audioGone:
                return "the recording is no longer in the folder"
            }
        }

        /// And for the recordings window, which does not. The pair sits on
        /// one type for the same reason `SessionInventory.Step` carries both
        /// `label` and `described`: the surfaces differ in language and in
        /// nothing else, and keeping the two versions a line apart is what
        /// stops one of them being changed alone.
        var described: String {
            switch self {
            case .unreadable:
                return localised("its meta.json can't be read", "не читается её meta.json")
            case .audioDiscarded:
                return localised(
                    "the audio was discarded after transcribing — keep_audio is off, "
                        + "so the transcript is all there is",
                    "звук выбросили после расшифровки — keep_audio выключен, "
                        + "и кроме расшифровки ничего не осталось")
            case .audioGone:
                return localised(
                    "the recording is no longer in the folder",
                    "записи больше нет в папке")
            }
        }
    }

    /// `meta` is the session's own account of itself, passed in by callers
    /// that have already read it; whether the audio survives is asked of the
    /// disk, because `files` stays true after the files are gone.
    static func obstacleToTranscribing(_ dir: URL, meta: [String: Any]? = nil) -> Obstacle? {
        guard let meta = meta ?? SessionState.read(dir) else { return .unreadable }
        let files = (meta["files"] as? [String: String]).map { Array($0.values) } ?? []
        let survives = files.contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        if survives { return nil }
        return meta["audio_discarded"] as? Bool == true ? .audioDiscarded : .audioGone
    }

    /// What `amanu process` should do with a session, decided before anything
    /// is printed or run.
    ///
    /// Separate from the command because this is the part with opinions in it:
    /// a session missing its transcript is transcribed from the audio it still
    /// has, one that was retired is left alone until somebody says `--again`,
    /// and one that can't be transcribed at all is refused in words rather
    /// than by doing nothing and reporting success.
    enum Plan: Equatable {
        /// Transcribe from the audio, first clearing what an earlier run left
        /// behind when there is anything to clear.
        case transcribe(clearingFirst: Bool)
        /// The transcript is there; only names and a summary can still be owed.
        case finish
        /// Nothing can be done, and this is what to say about it.
        case refuse(Refusal)
    }

    /// Why nothing can be done, in words rather than in a silence.
    ///
    /// A type rather than the sentence itself because both surfaces refuse
    /// and only one of them is in English: `description` is what `amanu
    /// process` prints, `described` is what the recordings window puts in an
    /// alert, and the two are a line apart so that a reason cannot be added
    /// to one surface alone.
    enum Refusal: Equatable, CustomStringConvertible {
        /// The config file cannot be read, carrying the parser's reason. Every
        /// plan waits on it: which engine, whether to summarize and where to,
        /// and the hook are all answers in the file.
        case configUnreadable(String)
        case transcriptionOff
        case cannotTranscribe(Obstacle)
        /// Retired without a transcript, carrying the reason it recorded —
        /// which came from an engine and stays in the language the engine
        /// said it in.
        case retired(String)

        var description: String {
            switch self {
            case .configUnreadable(let reason):
                return "\(Config.Unreadable(reason: reason)). Nothing in this session has "
                    + "been touched; fix the file and run this again."
            case .transcriptionOff:
                return "Transcription is off in the config, so there is nothing to "
                    + "transcribe with — set transcription.enabled back to true."
            case .cannotTranscribe(let obstacle):
                return "This session can't be transcribed: \(obstacle)."
            case .retired(let why):
                return "This session was retired without a transcript: \(why)\n"
                    + "Transcribe it from its audio anyway with `amanu process --again`."
            }
        }

        /// The window names its own button where the command line names its
        /// own flag: the two say the same thing, and neither sends a person
        /// looking for the other one.
        var described: String {
            switch self {
            case .configUnreadable(let reason):
                return localised(
                    "config.json can't be read (\(reason)), and until it can, transcription "
                        + "and summaries wait. Nothing in this recording has been touched.",
                    "config.json не читается (\(reason)), и пока это так, расшифровка и "
                        + "саммари ждут. В этой записи ничего не тронуто.")
            case .transcriptionOff:
                return localised(
                    "Transcription is off in the settings, so there is nothing to "
                        + "transcribe with — turn transcription.enabled back on.",
                    "Расшифровка выключена в настройках, расшифровывать нечем — "
                        + "включите transcription.enabled обратно.")
            case .cannotTranscribe(let obstacle):
                return localised(
                    "This recording can't be transcribed: \(obstacle.described).",
                    "Эту запись не расшифровать: \(obstacle.described).")
            case .retired(let why):
                return localised(
                    "This recording was retired without a transcript: \(why)\n"
                        + "Re-transcribe makes one from its audio anyway.",
                    "Эту запись оставили без расшифровки: \(why)\n"
                        + "Кнопка «Расшифровать заново» всё равно сделает её из звука.")
            }
        }
    }

    static func plan(
        for item: SessionInventory.Item,
        again: Bool = false,
        transcriptionEnabled: Bool = Config.transcriptionEnabled(),
        configProblem: String? = Config.unreadableReason
    ) -> Plan {
        // First, and before anything is cleared: `--again` used to delete the
        // transcript, the names and the summary and only then be refused by
        // the transcription it had cleared them for. A process started with
        // the file broken has no settings of its own to fall back on either.
        if let configProblem { return .refuse(.configUnreadable(configProblem)) }
        if item.transcript == .done, !again { return .finish }

        guard transcriptionEnabled else { return .refuse(.transcriptionOff) }
        if let obstacle = obstacleToTranscribing(item.dir) {
            return .refuse(.cannotTranscribe(obstacle))
        }
        // A retired session gave up for a reason it recorded, and some of
        // those reasons cost money to rediscover. Say what happened and let
        // the person decide, rather than deciding for them.
        if case .failed(let why) = item.transcript, !again {
            return .refuse(.retired(why))
        }
        return .transcribe(clearingFirst: again)
    }

    /// Request a fresh result without removing the completed one. Only successful
    /// recognition archives and replaces it; failure leaves every artifact readable.
    @discardableResult
    static func markForRetranscription(_ dir: URL) -> Bool {
        do {
            try SessionClaim.acquire(dir, stage: .transcribe)
            defer { SessionClaim.release(dir) }
            guard !DiarizationState.persisted(in: dir).isUnreadable else {
                appendSessionLog("can't replace unreadable saved diarization request", to: dir)
                return false
            }
            let engine = EngineResolver.configuredEngine(for: dir)
            try Data(engine.utf8).write(to: dir.appendingPathComponent(TranscriptVersions.requestFile), options: .atomic)
            try SessionState.amend(dir, with: [
                SessionState.Key.transcriptionFailed: nil,
                SessionState.Key.transcriptionAttempts: nil,
                SessionState.Key.transcriptionDeferred: nil,
            ])
            // The old speaker result still belongs to the current transcript
            // until a new transcript is committed. The coordinator snapshots
            // the current speaker switch and model for this new request.
            TranscriptionScratch.remove(in: dir, includingDerivedAudio: true)
            appendSessionLog("queued a new transcript version", to: dir)
            return true
        } catch {
            appendSessionLog("couldn't request re-transcription — \(error)", to: dir)
            return false
        }
    }

    /// Put a name to a label by hand, and re-render the transcript against it.
    ///
    /// Recorded as `manual`, which is what protects it: a later naming run
    /// merges around it rather than over it. Someone who corrected a name once
    /// shouldn't have to notice it was quietly undone.
    ///
    /// An empty name clears the entry back to unnamed, so a correction can be
    /// taken back as easily as it was made.
    ///
    /// The read, the change and the write are one step under the session's
    /// lock, the same one a naming run merges its answer under, so the two
    /// cannot write each other's work away.
    static func rename(_ label: String, to name: String?, in dir: URL) {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try SessionLock.withLock(dir) {
                var names = SpeakerNames.read(from: dir) ?? SpeakerNames()
                names.speakers[label] = SpeakerNames.Entry(
                    name: (cleaned?.isEmpty ?? true) ? nil : cleaned,
                    source: .manual
                )
                try names.write(to: dir)
                if let transcript = readTranscript(dir) {
                    try transcript.writeMarkdown(to: dir, names: names)
                }
                // The label now has an answer, so the session is no longer
                // waiting on a model for it.
                SessionState.update(dir, with: [SessionState.Key.speakersStatus: nil])
            }
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
