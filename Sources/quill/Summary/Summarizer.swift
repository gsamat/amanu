import Foundation

/// Turns a finished transcript into `summary.md`.
///
/// Three backends behind one interface, tried in order when `backend` is
/// `auto`: the Anthropic API if a key is around, then the local `claude` CLI
/// (which bills to the subscription already signed in on this machine rather
/// than per token), then ollama for the fully-offline case.
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
        into dir: URL
    ) async -> String? {
        func log(_ message: String) { appendSessionLog(message, to: dir) }

        let settings = Config.summary()
        guard settings.enabled, settings.backend != "none" else { return nil }

        let body = plainText(transcript)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("summary skipped — the transcript is empty")
            return nil
        }

        let backends = available(settings)
        guard !backends.isEmpty else {
            log("summary skipped — no backend available")
            return nil
        }

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
                guard !text.isEmpty else { throw SummaryError.emptyResponse(backend.name) }
                try Data((text + "\n").utf8).write(
                    to: dir.appendingPathComponent("summary.md"), options: .atomic
                )
                log("summary written by \(backend.name)")
                return backend.name
            } catch {
                // Try the next backend: an expired key or a stopped ollama
                // shouldn't cost the summary when another route works.
                log("summary via \(backend.name) failed: \(error)")
            }
        }
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

    private static let summaryInstructions = """
    Below is a meeting transcript with speaker labels.

    Write a Markdown note with exactly this structure:

    ## What this was about
    Two or three sentences: the topic and why they met.

    ## Key points
    5–10 substantive bullets. Each one a complete thought, not a fragment.

    ## Decisions
    What was decided. If nothing was, say that plainly.

    ## Action items
    Lines of "— who: what to do (deadline, if one was named)". If there are none, say so.

    ## Open questions
    What was left unresolved. Skip the section entirely if there's nothing.

    No preamble, no "here's your note" — start with the Markdown.
    """

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
        backend: Backend
    ) async throws -> String {
        let system = systemPrompt(language: settings.language)
        if body.count <= maxCharsPerCall {
            return try await backend.call(
                system, "\(header)\n\(summaryInstructions)\n\n---\n\(body)"
            )
        }

        let chunks = split(body, limit: maxCharsPerCall)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            notes.append(try await backend.call(
                system,
                "\(header)Part \(index + 1) of \(chunks.count).\n\(chunkInstructions)\n\n---\n\(chunk)"
            ))
        }
        return try await backend.call(
            system,
            "\(header)\n\(mergeInstructions)\n\(summaryInstructions)\n\n---\n"
                + notes.joined(separator: "\n\n---\n\n")
        )
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

    // MARK: - backends

    private struct Backend {
        let name: String
        let call: (String, String) async throws -> String
    }

    private static func available(_ settings: Config.SummarySettings) -> [Backend] {
        let key = Config.anthropicKey()
        let cli = claudePath()

        switch settings.backend {
        case "anthropic-api":
            guard let key else { return [] }
            return [anthropic(key: key, model: settings.model)]
        case "claude-cli":
            guard let cli else { return [] }
            return [claudeCLI(path: cli)]
        case "ollama":
            return [ollama(model: settings.ollamaModel)]
        default:
            var backends: [Backend] = []
            if let key { backends.append(anthropic(key: key, model: settings.model)) }
            if let cli { backends.append(claudeCLI(path: cli)) }
            backends.append(ollama(model: settings.ollamaModel))
            return backends
        }
    }

    private static func anthropic(key: String, model: String) -> Backend {
        Backend(name: "anthropic-api") { system, prompt in
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 4000,
                "system": system,
                "messages": [["role": "user", "content": prompt]],
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw SummaryError.http(http.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let content = json["content"] as? [[String: Any]]
            else { throw SummaryError.malformedResponse("anthropic-api") }
            return content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
    }

    /// The CLI is handed an empty MCP config on purpose: summarizing needs no
    /// tools, and without this it starts every MCP server the user has
    /// configured — minutes of startup for a one-shot prompt.
    private static func claudeCLI(path: String) -> Backend {
        Backend(name: "claude-cli") { system, prompt in
            try await runProcess(
                executable: path,
                arguments: [
                    "-p", system,
                    "--output-format", "text",
                    "--mcp-config", #"{"mcpServers":{}}"#,
                    "--strict-mcp-config",
                ],
                input: prompt,
                timeout: 1800
            )
        }
    }

    private static func ollama(model: String) -> Backend {
        Backend(name: "ollama") { system, prompt in
            var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 1800
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "prompt": "\(system)\n\n\(prompt)",
                "stream": false,
                "options": ["temperature": 0.2, "num_ctx": 32768],
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                var text = json["response"] as? String
            else { throw SummaryError.malformedResponse("ollama") }
            // Local reasoning models emit a thinking block before the answer.
            if let end = text.range(of: "</think>") {
                text = String(text[end.upperBound...])
            }
            return text
        }
    }

    private static func claudePath() -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a command with stdin, a deadline, and no shell in between.
    private static func runProcess(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        // Write and close before reading: the child blocks on EOF, we'd block
        // on its output, and neither would move.
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw SummaryError.exit(
                Int(task.terminationStatus),
                String(decoding: err.prefix(400), as: UTF8.self)
            )
        }
        return String(decoding: out, as: UTF8.self)
    }
}

enum SummaryError: Error, CustomStringConvertible {
    case emptyResponse(String)
    case malformedResponse(String)
    case http(Int, String)
    case exit(Int, String)

    var description: String {
        switch self {
        case .emptyResponse(let backend): return "\(backend) returned nothing"
        case .malformedResponse(let backend): return "\(backend) returned an unexpected shape"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .exit(let code, let stderr): return "exited \(code): \(stderr)"
        }
    }
}
