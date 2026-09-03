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
        _ = MainActor.assumeIsolated {
            RecordingSession.recoverInterrupted(root: root)
        }
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
/// is still a complete session: the audio to transcribe, and everything needed
/// to name its speakers and summarize it, is inside it. Sessions recorded
/// before 2026.08.18 still carry a `Finish processing.command` that calls this
/// with their own location, which is another reason it takes a path.
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

    @Flag(
        name: .long,
        help: "Transcribe again from the audio, discarding the transcript, names and summary."
    )
    var again = false

    func run() throws {
        let dir = URL(
            fileURLWithPath: (folder ?? FileManager.default.currentDirectoryPath as String)
                .expandingTilde,
            isDirectory: true
        ).standardizedFileURL

        let item = try Self.prepare(dir)
        Analytics.start(surface: .cli)
        defer { Analytics.flushOnExit() }
        print(item.summaryLine)

        switch PostProcessor.plan(for: item, again: again) {
        case .refuse(let why):
            print("")
            print(why)
            throw ExitCode(1)

        case .transcribe(let clearingFirst):
            if clearingFirst { PostProcessor.markForRetranscription(dir) }
            print("")
            print("Transcribing from the audio — this takes a while, and prints nothing "
                + "until it's done.")
            do {
                // The same coordinator the app runs, with a queue of one. On a
                // settled session it pulls the microphone and the far end back
                // out of audio.m4a a channel at a time; on one that never got
                // that far it reads the tracks as they were recorded.
                try runBlocking { try await TranscriptionCoordinator().transcribeNow(dir) }
            } catch let busy as SessionClaim.Busy {
                // The running app got to this folder first. Nothing has been
                // touched, and there is nothing to fix — so this reads as a
                // refusal rather than as a failure, and points at the copy of
                // amanu that is doing the work.
                print("")
                print(busy)
                throw ExitCode(1)
            } catch {
                print("")
                print("Transcription failed: \(error)")
                print(Self.logHint(dir))
                throw ExitCode(1)
            }

        case .finish:
            let work = try runBlocking { await PostProcessor.finish(dir) }
            if work.isEmpty {
                // Nothing done has two meanings and only one of them is good
                // news. A session the app is naming and summarizing right now
                // must not be reported as finished.
                if let holder = SessionClaim.holder(dir), holder.isAlive {
                    print("")
                    print(SessionClaim.Busy(session: dir.lastPathComponent, holder: holder))
                    throw ExitCode(1)
                }
                print("\nNothing to do — everything that can be done is done.")
                return
            }
        }

        print("")
        if let refreshed = SessionInventory.item(for: dir) {
            print(refreshed.summaryLine)
        }
        print("\n" + Self.logHint(dir))
    }

    static func prepare(_ dir: URL) throws -> SessionInventory.Item {
        _ = MainActor.assumeIsolated {
            RecordingSession.recoverInterrupted(root: dir.deletingLastPathComponent())
        }
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
        return item
    }

    private static func logHint(_ dir: URL) -> String {
        "See \(dir.appendingPathComponent("transcribe.log").lastPathComponent) for detail."
    }

    /// ArgumentParser's `run()` is synchronous, and this command is a one-shot
    /// process whose whole purpose is the async work — so waiting for it is
    /// the entire job rather than a blocked main thread.
    private func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}

extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
