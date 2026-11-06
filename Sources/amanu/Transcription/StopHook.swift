import Foundation

/// The `on_stop` hook: a shell command, given the session folder, run once a
/// session is finished.
///
/// The contract, which is the whole of this type:
///
/// - It fires **once per transcript**, when the session's post-processing has
///   had its pass: names and summary written, or turned off, or given up on,
///   or deferred for want of a model. A summary that arrives on a later sweep
///   does not fire it a second time — a Mac with no model to reach would
///   otherwise never run the hook at all.
/// - It never fires while any amanu — this one or another — is still naming
///   or summarizing the session. Whichever finishes that work fires it: the
///   transcription queue, the sweep at launch and on the network's return,
///   `amanu process`.
/// - With transcription off it fires once the recording has been archived.
/// - A session retired without a transcript does not fire it.
/// - Transcribing a session again owes the hook again.
///
/// It used to fire from the transcription queue the moment post-processing
/// returned — which was also the moment post-processing gave up because
/// another process had the session, so the hook was handed a folder with no
/// names and no summary in it; and a session whose post-processing a later
/// sweep did complete, after a crash or a quit, never fired it at all.
///
/// What is owed is written in meta.json, so that a process that dies
/// between the transcript and the hook leaves the debt for the next one.
/// Sessions recorded before the debt was written down owe nothing, which is
/// what keeps the first sweep after an update from running the hook over
/// every recording on the disk.
enum StopHook {
    static let key = "on_stop_hook"
    static let owed = "owed"
    static let fired = "fired"

    /// Record that this session's hook is due once its post-processing has run.
    static func owe(_ dir: URL) {
        SessionState.update(dir, with: [key: owed])
    }

    /// Fire the hook if this session owes it and nobody is working on the
    /// session. Returns whether it fired.
    ///
    /// Nothing is fired or marked while the config file cannot be read. The
    /// command is one of its answers, and `fired` is final: a debt settled
    /// with the default — no command at all — was a hook that never ran for
    /// that session, however soon the file was fixed. The debt stays in
    /// meta.json, and the sweep that follows the fix pays it.
    @discardableResult
    static func fireIfOwed(_ dir: URL, command: @autoclosure () -> String? = Config.onStop()) -> Bool {
        guard SessionState.value(dir, key) as? String == owed else { return false }
        guard !SpeakerReview.isPending(dir) else { return false }
        if let reason = Config.unreadableReason {
            appendSessionLog(
                "on_stop hook waits — config.json can't be read (\(reason))", to: dir)
            return false
        }
        // Taken, not just looked at: two processes finishing the same folder
        // at the same moment must not both decide the hook is theirs. A
        // session somebody else holds is theirs to fire when they let go.
        do {
            try SessionClaim.acquire(dir, stage: .finish)
        } catch {
            return false
        }
        defer { SessionClaim.release(dir) }
        guard SessionState.value(dir, key) as? String == owed else { return false }
        SessionState.update(dir, with: [key: fired])
        guard let command = command() else { return false }
        run(command, in: dir)
        return true
    }

    /// The command with the folder as `$0`, so a path with spaces or quotes
    /// in it reaches the command as one argument rather than as shell text.
    private static func run(_ command: String, in dir: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(command) \"$0\"", dir.path]
        // The session it was fired for is the only sensible place to stand.
        task.currentDirectoryURL = dir
        do {
            try task.run()
            appendSessionLog("on_stop hook started", to: dir)
        } catch {
            appendSessionLog("on_stop hook failed to launch: \(error)", to: dir)
        }
    }
}
