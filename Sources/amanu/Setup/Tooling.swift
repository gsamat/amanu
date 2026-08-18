import Foundation

/// Finding the command-line tools amanu borrows — `claude`, `codex`, `ollama`
/// — on a machine where they may not be where a list of three paths expects.
///
/// Three things make this harder than `which`, and each of them produces the
/// same wrong answer ("not installed") about a tool that is sitting right
/// there:
///
/// 1. **The app's PATH is not yours.** macOS hands a launched app a minimal
///    environment, so anything installed through homebrew's node, mise, volta,
///    fnm or bun is invisible to us and visible to you. Asking the login shell
///    is the only way to see what you see.
/// 2. **A desktop app can be the install.** ChatGPT.app carries a working
///    `codex` binary inside its bundle, and someone who has never opened a
///    terminal has it and nothing else.
/// 3. **A file is not a working tool.** A path that exists proves nothing;
///    running it and getting a version back proves everything worth proving,
///    and it is the check that catches the case above where the binary is
///    found but cannot run from where we are.
///
/// Answers are cached for the life of the process: the login shell costs a few
/// hundred milliseconds, `--version` costs a spawn, and neither answer changes
/// often enough to pay that per summary.
enum Tooling {
    /// A tool as far as we can tell — where it is, and what it said when run.
    struct Found: Equatable {
        let name: String
        let path: String
        /// The first line of `--version`. nil means the file is there and did
        /// not answer, which for our purposes is the same as absent — but is
        /// worth saying differently, because the fix is different.
        let version: String?

        var runs: Bool { version != nil }
    }

    /// Well-known install locations, in the order they're tried. `~/.local/bin`
    /// first because that's where both official installers put their entry
    /// point (for Claude Code, a symlink into `~/.local/share/claude`, which
    /// is also what the desktop app manages).
    private static func standardLocations(for name: String) -> [String] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
    }

    /// Binaries shipped inside a desktop app's bundle. Verified present in
    /// ChatGPT.app; Claude.app carries no `claude` binary and installs one
    /// into `~/.local/bin` instead, which `standardLocations` already covers.
    private static func bundledLocations(for name: String) -> [String] {
        switch name {
        case "codex": return ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        default: return []
        }
    }

    // MARK: - looking

    /// The path to a tool, or nil. Cheap after the first call.
    static func path(for name: String) -> String? {
        cache.path(for: name)
    }

    /// The tool, run once to see whether it answers. Cheap after the first call.
    static func probe(_ name: String) -> Found? {
        guard let path = path(for: name) else { return nil }
        return Found(name: name, path: path, version: cache.version(of: name, at: path))
    }

    /// Forget what we found, so the next look goes out to the disk and the
    /// shell again — for after someone has installed something and come back.
    static func forget() { cache.clear() }

    /// Whether ollama is answering on its usual port, and with which models.
    /// nil means nothing is listening: not an error, just the common case.
    static func ollamaModels() async -> [String]? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        request.timeoutInterval = 2
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    // MARK: - the cache

    private static let cache = Cache()

    /// Shared mutable state behind a lock rather than an actor: every caller
    /// here is synchronous, and making them all async to protect two
    /// dictionaries would spread through the summarizer for nothing.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: String?] = [:]
        private var versions: [String: String?] = [:]

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            paths = [:]
            versions = [:]
        }

        func path(for name: String) -> String? {
            lock.lock()
            if let known = paths[name] {
                lock.unlock()
                return known
            }
            lock.unlock()

            let found = Tooling.search(for: name)

            lock.lock()
            paths[name] = found
            lock.unlock()
            return found
        }

        func version(of name: String, at path: String) -> String? {
            lock.lock()
            if let known = versions[name] {
                lock.unlock()
                return known
            }
            lock.unlock()

            let answer = Tooling.askVersion(of: path)

            lock.lock()
            versions[name] = answer
            lock.unlock()
            return answer
        }
    }

    // MARK: - the search itself

    private static func search(for name: String) -> String? {
        let fm = FileManager.default
        if let found = (standardLocations(for: name) + bundledLocations(for: name))
            .first(where: { fm.isExecutableFile(atPath: $0) }) {
            return found
        }
        return fromLoginShell(name)
    }

    /// Ask the user's login shell where the tool is, because that shell is the
    /// only thing that knows about their version manager. Interactive (`-i`)
    /// as well as login (`-l`): on macOS zsh, homebrew's shellenv usually
    /// lives in `.zprofile` but mise, asdf and nvm nearly always live in
    /// `.zshrc`, which only an interactive shell reads.
    ///
    /// Failures here are silent and expected: a shell with a prompt that waits
    /// for something, a shell that isn't zsh or bash, no shell at all.
    private static func fromLoginShell(_ name: String) -> String? {
        let shell: String = {
            if let fromEnvironment = ProcessInfo.processInfo.environment["SHELL"],
               !fromEnvironment.isEmpty {
                return fromEnvironment
            }
            // A launched app has no SHELL; the account record always has one.
            if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
                return String(cString: shell)
            }
            return "/bin/zsh"
        }()
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        guard let output = run(
            shell, ["-lic", "command -v \(name)"], timeout: 8
        ) else { return nil }

        // `command -v` prints a path, but a login shell prints whatever else
        // the dotfiles feel like printing, so take the last line that looks
        // like an executable rather than trusting the first.
        let path = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        return path
    }

    /// Run it. Not "does the file exist" — the whole point of this pass is the
    /// machine where the file exists and running it from here doesn't work.
    private static func askVersion(of path: String) -> String? {
        guard let output = run(path, ["--version"], timeout: 20) else { return nil }
        let line = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return nil }
        return String(line.prefix(60))
    }

    /// A subprocess with a deadline and no shell in between, returning stdout
    /// on a clean exit and nil on anything else. Deliberately quiet: every
    /// caller here is asking a question that is allowed to be answered "no".
    private static func run(_ executable: String, _ arguments: [String],
                            timeout: TimeInterval) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        // Somewhere it can't matter what's in the directory: `codex` and
        // `claude` both look around the working directory when they start.
        task.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        // A login shell with no input to read must see EOF, not a terminal, or
        // it sits waiting for a line that will never come.
        task.standardInput = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
