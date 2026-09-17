import ArgumentParser
import Foundation

/// `amanu transcribe <file>...` — the text of a recording amanu did not make.
///
/// A dictaphone file, a downloaded talk, a voice message somebody sent: the
/// model that transcribes meetings is on this Mac already, and until now the
/// only way to point it at a file was File ▸ Import in the running app. From a
/// terminal there was no way in, so people keep a second copy of the same
/// model beside amanu's, in another format, just to run it from a script.
///
/// Nothing here transcribes anything itself. The file goes through the
/// importer the menu uses — one session in the recordings folder, known by
/// its hash — and then through the transcription `amanu process` runs, so the
/// engine, the language and the models are whatever the configuration already
/// chose. What is new is the last step: the transcript is rendered beside the
/// source, or to standard output, where a person, a video player or a script
/// can pick it up without knowing what a session folder is.
///
/// Standard output carries only that — the paths written, or the text itself
/// with `--stdout` — and everything said along the way goes to standard error,
/// so `cat "$(amanu transcribe note.m4a)"` reads the transcript and nothing
/// else. A file that cannot be transcribed is reported and skipped, the rest
/// still get their turn, and the exit status says whether any of them failed.
struct TranscribeFile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe audio or video files amanu did not record."
    )

    @Argument(help: "The audio or video files to transcribe.")
    var files: [String]

    @Option(name: .long, help: "What to write: txt, srt or vtt. Repeat the flag for more than one.")
    var format: [TranscriptText.Format] = [.txt]

    @Option(name: .long, help: "Write the text here instead of beside each file.")
    var outputDir: String?

    @Flag(name: .customLong("stdout"), help: "Print the transcript instead of writing it to a file.")
    var toStandardOutput = false

    @Flag(name: .long, help: "Also name the speakers and write a summary, as for a meeting.")
    var summary = false

    func validate() throws {
        if toStandardOutput, outputDir != nil {
            throw ValidationError("--stdout prints the transcript; there is nowhere for --output-dir to put it.")
        }
        if toStandardOutput, Set(format).count > 1 || files.count > 1 {
            throw ValidationError("--stdout prints one transcript in one format; pick one file and one format.")
        }
        // Checked before any model is loaded: a typo in the third of five
        // paths should not cost the first two their transcription first.
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw ValidationError("there is no file at \(source.path).")
            }
            if isDirectory.boolValue {
                throw ValidationError(
                    "\(source.path) is a folder — name the files in it, "
                        + "for instance `amanu transcribe \(source.path)/*.m4a`.")
            }
        }
        // Two sources with one name would take turns writing the same file,
        // and the second would win without a word.
        let names = sources.map { $0.deletingPathExtension().lastPathComponent }
        if let repeated = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 }) {
            throw ValidationError(
                "\(repeated.key) is the name of more than one of these files, "
                    + "so their transcripts would overwrite each other.")
        }
    }

    private var sources: [URL] {
        files.map { URL(fileURLWithPath: $0.expandingTilde).standardizedFileURL }
    }

    func run() throws {
        let directory = try outputDir.map(Self.outputDirectory)
        let formats = Set(format).sorted { $0.rawValue < $1.rawValue }
        let sources = sources
        let toStandardOutput = toStandardOutput

        Analytics.start(surface: .cli)
        defer { Analytics.flushOnExit() }

        // Not cleaning the recordings folder's staging: this process may be
        // running beside the app, or beside another copy of itself, and a
        // half-written `.import-*` folder there is somebody's work in flight.
        let transcriber = FileTranscriber(
            importer: MediaImportCoordinator(
                root: Config.resolveRoot(cliOverride: nil), removingStaleStaging: false),
            transcription: TranscriptionCoordinator(),
            summary: summary,
            report: Self.say)

        let failed = try runBlocking {
            var failed: [String] = []
            for source in sources {
                do {
                    let result = try await transcriber.transcribe(source)
                    for format in formats {
                        let text = TranscriptText.render(
                            result.transcript, as: format, names: result.names)
                        if toStandardOutput {
                            print(text, terminator: "")
                            continue
                        }
                        let written = Self.destination(for: source, format: format, in: directory)
                        try Data(text.utf8).write(to: written, options: .atomic)
                        print(written.path)
                    }
                } catch {
                    failed.append(source.lastPathComponent)
                    Self.say("\(source.lastPathComponent): \(error)")
                }
            }
            return failed
        }

        if sources.count > 1 {
            let tally = "transcribed \(sources.count - failed.count) of \(sources.count) files"
            Self.say(failed.isEmpty ? tally : tally + ", failed: " + failed.joined(separator: ", "))
        }
        if !failed.isEmpty { throw ExitCode(1) }
    }

    /// Where one rendering goes: the source's own name with the format's
    /// extension, in the folder asked for or else beside the source — which
    /// for `talk.mp4` puts `talk.srt` exactly where a video player looks.
    static func destination(for source: URL, format: TranscriptText.Format, in directory: URL?) -> URL {
        (directory ?? source.deletingLastPathComponent())
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format.rawValue)
    }

    private static func outputDirectory(_ path: String) throws -> URL {
        let directory = URL(fileURLWithPath: path.expandingTilde, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

extension TranscriptText.Format: ExpressibleByArgument {}

/// The work behind `amanu transcribe`, one file at a time: import, transcribe
/// unless that was done before, and hand back what there is to render.
///
/// Its two collaborators are handed in rather than made here so a test can
/// run the whole route with a fake engine — the way the coordinator is
/// tested — and see what it leaves in the recordings folder.
struct FileTranscriber: Sendable {
    struct Result: Sendable {
        let session: URL
        let transcript: Transcript
        let names: SpeakerNames?
    }

    /// Why a file got no transcript, in one sentence for the terminal.
    struct Refused: Error, CustomStringConvertible {
        let description: String
    }

    let importer: MediaImportCoordinator
    let transcription: TranscriptionCoordinator
    /// Whether the session is to be finished as a meeting would be — speaker
    /// names, then a summary — or left at its transcript.
    let summary: Bool
    var transcriptionEnabled: Bool = Config.transcriptionEnabled()
    /// What the person is told while a file is being worked on.
    let report: @Sendable (String) -> Void

    func transcribe(_ source: URL) async throws -> Result {
        // Refused before importing, not after: with transcription off there
        // is nothing to transcribe with, and a session left behind would be
        // picked up by the queue the day the setting came back on.
        guard transcriptionEnabled else {
            throw Refused(description: "\(PostProcessor.Refusal.transcriptionOff)")
        }
        let session = try await session(for: source)
        guard let item = SessionInventory.item(for: session) else {
            throw Refused(description: "couldn't read \(session.path)/meta.json.")
        }

        // The same decision `amanu process` makes about a folder, so a file
        // amanu has given up on is refused in the same words, with the same
        // way back, rather than being run through the model on every try.
        switch PostProcessor.plan(for: item, transcriptionEnabled: transcriptionEnabled) {
        case .refuse(let why):
            throw Refused(description: "\(why)\nThe session is \(session.path).")
        case .transcribe:
            report("transcribing \(source.lastPathComponent) — this takes a while, "
                + "and prints nothing until it's done")
            do {
                try await transcription.transcribeNow(session)
            } catch let busy as SessionClaim.Busy {
                throw Refused(description: "\(busy)")
            } catch {
                throw Refused(description: "transcription failed: \(error)\nSee "
                    + session.appendingPathComponent("transcribe.log").path + " for detail.")
            }
        case .finish:
            report("\(source.lastPathComponent) was transcribed before — "
                + "reusing \(session.lastPathComponent)")
            // Whatever the session still owes by its own reading of the
            // config: nothing, for one this command made — unless `--summary`
            // has just taken its note back — and the names and summary any
            // imported meeting is owed, for one the menu made.
            await PostProcessor.finish(session)
        }

        guard let transcript = PostProcessor.readTranscript(session) else {
            throw Refused(description:
                "nothing was transcribed for \(source.lastPathComponent) — see \(session.path).")
        }
        let summaryFile = session.appendingPathComponent("summary.md")
        if summary, FileManager.default.fileExists(atPath: summaryFile.path) {
            report("summary: \(summaryFile.path)")
        }
        return Result(session: session, transcript: transcript, names: SpeakerNames.read(from: session))
    }

    /// The session this file belongs to: the one the importer just made for
    /// it, or the one an earlier import already did. The importer knows a
    /// file by its hash, which is what makes a second run cheap — asking for
    /// another format re-renders the transcript instead of running the model.
    private func session(for source: URL) async throws -> URL {
        let result = await importer.importFiles([source])
        if let failure = result.failures.first {
            throw Refused(description: failure.message)
        }
        guard let session = result.imported.first?.session
            ?? result.duplicates.first?.existingSession
        else {
            throw Refused(description: "importing \(source.lastPathComponent) was interrupted.")
        }

        // A session this command made is told what it was asked for, so that
        // neither this run nor the app's next sweep goes looking for names
        // and a summary. One the menu imported is left with the fate the
        // menu gave it: a duplicate is reused, not re-decided. `--summary`
        // takes the note back either way, because now somebody has asked.
        if summary {
            SessionState.update(session, with: [SessionState.Key.transcriptOnly: nil])
        } else if result.imported.first != nil {
            SessionState.update(session, with: [SessionState.Key.transcriptOnly: true])
        }
        return session
    }
}
