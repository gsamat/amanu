import Foundation

/// `.transcribing.json` — who is working on a session folder right now.
///
/// The app and `amanu process` are two processes over one recordings folder,
/// and both are meant to be usable at once: the menu bar drains its queue while
/// a person runs the command line on a session by hand. Nothing in the folder
/// said who owned a session, so both could pick up the same one, both upload
/// the same audio to AssemblyAI, and both be charged for it — and then both ask
/// a language model for the same name and the same summary (.issues/004).
///
/// So a claim file, exactly as `.recording.json` marks a folder as being
/// recorded into: dot-prefixed, holding the owner's pid and when it started,
/// and stale-checked by asking whether that pid is still alive. It also carries
/// the `stage`, because the two things worth not paying for twice are the
/// transcript and the post-processing, and a log line reads better saying which
/// one is in progress.
///
/// Unlike the recording marker, this one can genuinely be raced for — two
/// processes may reach for the same folder in the same instant — so it is
/// written whole under a private name and then linked into place, which
/// fails for the loser rather than letting both continue. Taking over a dead
/// owner's claim is the other race, and that one is decided under the
/// session's lock.
enum SessionClaim {
    /// Beside `.recording.json`, and dot-prefixed for the same reason: this is
    /// bookkeeping, and a person opening the folder in the Finder is looking
    /// for their recording.
    static let file = ".transcribing.json"

    /// Which of the two cost centres the owner is in. One file covers both:
    /// they never run at the same time on one session, and a single marker is
    /// one thing to reason about when it is left behind by a crash.
    enum Stage: String {
        case transcribe
        case finish
        case review
    }

    /// A claim as it is on disk, whether or not the process that wrote it is
    /// still there.
    struct Holder {
        let pid: Int32
        /// Nil only when the claim was written by something that did not put a
        /// readable `started` in it; every version of amanu does.
        let started: Date?
        let stage: String
        /// The same liveness test `RecordingSession.recoverInterrupted` uses,
        /// with the same caveat: a recycled pid could fool it. Here the cost of
        /// being wrong is a session left for the next scan to pick up, which is
        /// again the safe direction — the expensive mistake is transcribing
        /// twice, not transcribing a minute later. `EPERM` counts as alive: it
        /// is a process we may not signal, not a process that is gone.
        var isAlive: Bool { RecordingSession.processIsAlive(pid) }
    }

    /// Somebody else is doing this work. Not a transcription failure: nothing
    /// went wrong, the session simply belongs to another process for now, so
    /// whoever catches this must leave the folder as it is rather than counting
    /// an attempt against it.
    struct Busy: Error, CustomStringConvertible {
        let session: String
        /// Nil when the claim file is there but can't be read, which is the one
        /// case where we know nothing except that we must not touch anything.
        let holder: Holder?

        var description: String {
            guard let holder else {
                return "Something else is already working on this recording: its "
                    + "\(SessionClaim.file) can't be read, so amanu is leaving the folder "
                    + "alone. Delete that file if no other copy of amanu is running."
            }
            let what = holder.stage == Stage.review.rawValue
                ? "reviewing the speakers in this recording"
                : (holder.stage == Stage.finish.rawValue
                    ? "naming and summarizing this recording" : "transcribing this recording")
            // The owner can be this very process — the sweep and the button
            // reach for folders the transcription queue is already in — and
            // telling somebody to quit the copy they are reading the message
            // from would be nonsense.
            guard holder.pid != ProcessInfo.processInfo.processIdentifier else {
                return "This copy of amanu is already \(what) — leaving it to the run "
                    + "that has it."
            }
            return "Another amanu (pid \(holder.pid)) is already \(what). Let it finish, "
                + "or quit it and run this again."
        }

        /// The same account for the recordings window, which a person reads
        /// in their own language and which is never the command line.
        var described: String {
            guard let holder else {
                return localised(
                    "Something else is already working on this recording: its "
                        + "\(SessionClaim.file) can't be read, so amanu is leaving it alone.",
                    "Этой записью уже кто-то занят: её \(SessionClaim.file) не читается, "
                        + "поэтому amanu её не трогает.")
            }
            if holder.stage == Stage.review.rawValue {
                return localised("Speaker names are being reviewed in Amanu.",
                                 "В Amanu открыто именование участников этой записи.")
            }
            let finishing = holder.stage == Stage.finish.rawValue
            guard holder.pid != ProcessInfo.processInfo.processIdentifier else {
                return finishing
                    ? localised(
                        "amanu is naming and summarizing this recording right now.",
                        "amanu прямо сейчас подбирает имена и пишет саммари для этой записи.")
                    : localised(
                        "amanu is transcribing this recording right now.",
                        "amanu прямо сейчас расшифровывает эту запись.")
            }
            return finishing
                ? localised(
                    "Another amanu (pid \(holder.pid)) is naming and summarizing this "
                        + "recording. Let it finish, then try again.",
                    "Другая amanu (pid \(holder.pid)) подбирает имена и пишет саммари для "
                        + "этой записи. Дайте ей закончить и попробуйте снова.")
                : localised(
                    "Another amanu (pid \(holder.pid)) is transcribing this recording. "
                        + "Let it finish, then try again.",
                    "Другая amanu (pid \(holder.pid)) расшифровывает эту запись. "
                        + "Дайте ей закончить и попробуйте снова.")
        }
    }

    /// How long an unreadable claim is taken at its word.
    ///
    /// This version never leaves one: the claim is complete before it has its
    /// name. An older amanu created the file and then filled it, so for an
    /// instant a live claim was empty — and a crash or a full disk in that
    /// instant left an empty claim nothing would ever remove, the session
    /// held for good by nobody. A minute is thousands of times the instant
    /// and still short against a session that would otherwise never finish.
    static let unreadableGrace: TimeInterval = 60

    /// What is on disk, as far as anyone may act on it.
    enum State {
        case absent
        case held(Holder)
        /// There, and not a claim anyone can read. `since` is its
        /// modification date, which decides whether it is still being
        /// written or was abandoned.
        case unreadable(since: Date?)
    }

    static func state(_ dir: URL) -> State {
        let url = url(dir)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        if let holder = holder(dir) { return .held(holder) }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate] as? Date
        return .unreadable(since: modified)
    }

    /// Whether an unreadable claim is young enough that its writer may still
    /// be filling it in.
    private static func isFresh(_ since: Date?, now: Date = Date()) -> Bool {
        guard let since else { return true }
        return now.timeIntervalSince(since) < unreadableGrace
    }

    /// Whether somebody else has this session — a live owner, or a claim file
    /// that can't be read and is recent, which is treated as held for the same
    /// reason `recoverInterrupted` leaves an unreadable manifest alone: not
    /// knowing who owns a folder is not a licence to take it. An unreadable
    /// claim older than `unreadableGrace` is litter, like a dead owner's.
    static func isHeld(_ dir: URL) -> Bool {
        switch state(dir) {
        case .absent: return false
        case .held(let holder): return holder.isAlive
        case .unreadable(let since): return isFresh(since)
        }
    }

    /// What the claim file says, or nil when there isn't one or it can't be
    /// parsed.
    static func holder(_ dir: URL) -> Holder? {
        guard
            let data = try? Data(contentsOf: url(dir)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = json["pid"] as? Int32
        else { return nil }
        return Holder(
            pid: pid,
            started: (json["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
            stage: json["stage"] as? String ?? Stage.transcribe.rawValue
        )
    }

    /// Take the session, or say who has it.
    ///
    /// Every caller must pair this with a `release` in a `defer`, so that the
    /// success path, the throwing path and any retry inside it all give the
    /// folder back. A process killed between the two leaves the file behind;
    /// the next run finds its pid dead and reclaims it, which is the same
    /// bargain crash recovery already makes with `.recording.json`.
    static func acquire(_ dir: URL, stage: Stage) throws {
        if try create(url(dir), stage: stage) { return }

        // Somebody got there first. An owner still running keeps it; one that
        // died mid-transcription left litter, and litter must not retire a
        // session for ever.
        //
        // Deciding that it is litter and replacing it happen under the
        // session's lock, and the claim is read again inside it. Two
        // processes used to read the same dead pid, and the slower one then
        // deleted the claim the faster one had just written in its place and
        // wrote its own — both believing they had the session, both paying
        // for it (.issues/004). Under the lock the second reader finds the
        // first one's live claim and is refused.
        try SessionLock.withLock(dir) {
            switch state(dir) {
            case .absent:
                // Released between our attempt and the lock.
                guard try create(url(dir), stage: stage) else {
                    throw Busy(session: dir.lastPathComponent, holder: holder(dir))
                }
            case .held(let holder) where holder.isAlive:
                throw Busy(session: dir.lastPathComponent, holder: holder)
            case .held(let holder):
                try replace(url(dir), stage: stage)
                appendSessionLog(
                    "reclaiming \(file) from pid \(holder.pid), which is no longer running",
                    to: dir)
            case .unreadable(let since) where isFresh(since):
                throw Busy(session: dir.lastPathComponent, holder: nil)
            case .unreadable:
                try replace(url(dir), stage: stage)
                appendSessionLog(
                    "reclaiming \(file), which could not be read and has not changed in "
                        + "over a minute", to: dir)
            }
        }
    }

    /// Give the session back — but only if it is still ours. A release that
    /// deleted whatever was there would hand the folder to a third process at
    /// exactly the moment a second one had legitimately reclaimed it.
    static func release(_ dir: URL) {
        SessionLock.withLock(dir) {
            guard holder(dir)?.pid == ProcessInfo.processInfo.processIdentifier else { return }
            try? FileManager.default.removeItem(at: url(dir))
        }
    }

    /// Transfer this process's existing claim without a release/acquire race.
    static func changeStage(_ dir: URL, to stage: Stage) throws {
        try SessionLock.withLock(dir) {
            guard holder(dir)?.pid == ProcessInfo.processInfo.processIdentifier else {
                throw Busy(session: dir.lastPathComponent, holder: holder(dir))
            }
            try payload(stage: stage).write(to: url(dir), options: .atomic)
        }
    }

    // MARK: -

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent(file) }

    /// What a claim by this process says.
    private static func payload(stage: Stage) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "started": ISO8601DateFormatter().string(from: Date()),
                "stage": stage.rawValue,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Create the claim file if nobody else has, and say whether we did.
    ///
    /// The claim is written in full under a name of its own and then
    /// `link`ed to the real one. `link` fails if the name is taken, which is
    /// the `O_EXCL` a rival must meet, and unlike creating the real file and
    /// then writing into it, the claim is never visible half-written: a full
    /// disk fails the private file, which is removed, and leaves no claim at
    /// all rather than an empty one that holds the session for nobody.
    static func create(
        _ url: URL,
        stage: Stage,
        write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    ) throws -> Bool {
        let staged = try writeStaged(url, stage: stage, write: write)
        defer { unlink(staged.path) }
        if link(staged.path, url.path) == 0 { return true }
        if errno == EEXIST { return false }
        throw ClaimError.cannotWrite(url, String(cString: strerror(errno)))
    }

    /// Put our claim in place of a dead one. `rename` swaps the file in one
    /// step, so there is no moment without a claim for a newcomer's `link` to
    /// slip into; only the session lock, held by the caller, makes it ours to
    /// swap.
    private static func replace(_ url: URL, stage: Stage) throws {
        let staged = try writeStaged(url, stage: stage) { try $0.write(contentsOf: $1) }
        guard rename(staged.path, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(staged.path)
            throw ClaimError.cannotWrite(url, why)
        }
    }

    /// The claim, complete, under a private name beside the real one.
    private static func writeStaged(
        _ url: URL, stage: Stage, write: (FileHandle, Data) throws -> Void
    ) throws -> URL {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent("\(file).\(UUID().uuidString).tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw ClaimError.cannotWrite(url, String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try write(handle, try payload(stage: stage))
            try handle.close()
        } catch {
            try? handle.close()
            unlink(staged.path)
            throw ClaimError.cannotWrite(url, "\(error)")
        }
        return staged
    }

    /// The session folder itself is unwritable, which is a real failure rather
    /// than a busy signal: whoever is transcribing needs to hear about it.
    enum ClaimError: Error, CustomStringConvertible {
        case cannotWrite(URL, String)

        var description: String {
            switch self {
            case .cannotWrite(let url, let why): return "can't write \(url.path): \(why)"
            }
        }
    }
}
