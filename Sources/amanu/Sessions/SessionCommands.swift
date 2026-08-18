import ArgumentParser
import Foundation

/// `amanu sessions` — what has been recorded and what is still owed on it.
struct Sessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "List recordings and what still needs doing to them."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(name: .long, help: "Only sessions with work outstanding.")
    var pending = false

    func run() throws {
        let root = Config.resolveRoot(cliOverride: out)
        let items = SessionInventory.scan(root: root)
            .filter { !pending || $0.isOutstanding }

        guard !items.isEmpty else {
            print(pending ? "Nothing outstanding." : "No recordings in \(root.path).")
            return
        }
        for item in items {
            print(item.summaryLine)
            print("    \(item.dir.path)")
            print("")
        }
        let outstanding = items.count { $0.isOutstanding }
        print("\(items.count) session(s), \(outstanding) with work outstanding.")
    }
}

/// `amanu process <folder>` — finish one session, wherever it lives now.
///
/// Takes an arbitrary path rather than a session name on purpose. The folder
/// in question may have been moved out of the recordings root entirely, and it
/// is still a complete session: everything needed to name its speakers and
/// summarize it is inside it. This is also what the folder's own
/// `Finish processing.command` calls, handing over its own location.
///
/// Named `ProcessSession` rather than `Process` because the latter is
/// `Foundation.Process`: a command type shadowing it breaks every subprocess
/// in the program, including the CLI model backends this command depends on.
struct ProcessSession: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Finish a recording: speaker names, summary, or a missing transcript."
    )

    @Argument(help: "The session folder. Defaults to the current directory.")
    var folder: String?

    func run() throws {
        let dir = URL(
            fileURLWithPath: (folder ?? FileManager.default.currentDirectoryPath as String)
                .expandingTilde,
            isDirectory: true
        ).standardizedFileURL

        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meta.json").path
        ) else {
            throw ValidationError(
                "\(dir.path) doesn't look like a recording — no meta.json in it."
            )
        }

        guard let item = SessionInventory.item(for: dir) else {
            throw ValidationError("couldn't read \(dir.path)/meta.json.")
        }
        print(item.summaryLine)

        // A retired session has no transcript to work from, and re-running
        // transcription needs the daemon's queue and its engine. Say so rather
        // than silently doing the two cheap steps and calling it finished.
        if case .failed(let why) = item.transcript {
            print("")
            print("This session was retired without a transcript: \(why)")
            print("Re-transcribing happens in the app — open the recordings list,")
            print("or delete transcription_failed from its meta.json and restart amanu.")
            throw ExitCode(1)
        }

        let work = runBlocking { await PostProcessor.finish(dir) }
        if work.isEmpty {
            print("\nNothing to do — everything that can be done is done.")
            return
        }

        print("")
        if let refreshed = SessionInventory.item(for: dir) {
            print(refreshed.summaryLine)
        }
        print("\nSee \(dir.appendingPathComponent("transcribe.log").lastPathComponent) for detail.")
    }

    /// ArgumentParser's `run()` is synchronous, and this command is a one-shot
    /// process whose whole purpose is the async work — so waiting for it is
    /// the entire job rather than a blocked main thread.
    private func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
