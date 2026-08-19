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
/// created with `O_EXCL` and the loser is told, rather than written over the
/// top and both continuing.
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
        /// twice, not transcribing a minute later.
        var isAlive: Bool { kill(pid, 0) == 0 }
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
            let what = holder.stage == Stage.finish.rawValue
                ? "naming and summarizing this recording"
                : "transcribing this recording"
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
    }

    /// Whether somebody else has this session — a live owner, or a claim file
    /// that can't be read, which is treated as held for the same reason
    /// `recoverInterrupted` leaves an unreadable manifest alone: not knowing who
    /// owns a folder is not a licence to take it.
    static func isHeld(_ dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url(dir).path) else { return false }
        guard let holder = holder(dir) else { return true }
        return holder.isAlive
    }

    /// What the claim file says, or nil when there isn't one or it can't be
    /// parsed. A claim being written is momentarily an empty file — the create
    /// and the contents cannot be one operation — and that reads as unparsable,
    /// which sends a rival to back off. That is the right answer for the
    /// instant it lasts.
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
        guard let holder = holder(dir) else {
            throw Busy(session: dir.lastPathComponent, holder: nil)
        }
        guard !holder.isAlive else {
            throw Busy(session: dir.lastPathComponent, holder: holder)
        }

        try? FileManager.default.removeItem(at: url(dir))
        appendSessionLog(
            "reclaiming \(file) from pid \(holder.pid), which is no longer running", to: dir)
        // One retry only: a second collision means a third process is in this
        // folder too, and racing it round a loop is worse than coming back.
        guard try create(url(dir), stage: stage) else {
            throw Busy(session: dir.lastPathComponent, holder: Self.holder(dir))
        }
    }

    /// Give the session back — but only if it is still ours. A release that
    /// deleted whatever was there would hand the folder to a third process at
    /// exactly the moment a second one had legitimately reclaimed it.
    static func release(_ dir: URL) {
        guard holder(dir)?.pid == ProcessInfo.processInfo.processIdentifier else { return }
        try? FileManager.default.removeItem(at: url(dir))
    }

    // MARK: -

    static func url(_ dir: URL) -> URL { dir.appendingPathComponent(file) }

    /// Create the claim file if nobody else has, and say whether we did.
    /// `O_EXCL` rather than the atomic write the manifest uses, because this is
    /// the one marker two processes reach for at once: a write-and-rename would
    /// let both of them believe they won.
    private static func create(_ url: URL, stage: Stage) throws -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if descriptor < 0 {
            if errno == EEXIST { return false }
            throw ClaimError.cannotWrite(url, String(cString: strerror(errno)))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let json = try JSONSerialization.data(
            withJSONObject: [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "started": ISO8601DateFormatter().string(from: Date()),
                "stage": stage.rawValue,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try handle.write(contentsOf: json)
        try? handle.close()
        return true
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
