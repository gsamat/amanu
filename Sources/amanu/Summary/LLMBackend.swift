import Foundation

/// One way of asking a language model a question, and the ordered list of ways
/// available on this machine.
///
/// The order encodes a preference: **a subscription you already pay for beats a
/// metered API key**. The local `claude` and `codex` CLIs bill against
/// subscriptions already signed in here, so they go first; the API keys are
/// what catches a CLI that isn't installed or has run out of allowance; ollama
/// is the floor that needs neither network nor account.
///
/// Every backend is a fallback for the one before it, so a summary survives an
/// expired key, an exhausted subscription, or a plane.
struct LLMBackend {
    let name: String
    /// (system prompt, user prompt) → completion text.
    let call: (String, String) async throws -> String

    /// The backends to try, in order.
    ///
    /// - Parameter preference: `auto` (default) or an explicit backend name;
    ///   an explicit name returns just that one, so a deliberate choice is
    ///   never silently second-guessed.
    static func available(preference: String = "auto") -> [LLMBackend] {
        let settings = Config.summary()
        let claude = cliPath("claude")
        let codex = cliPath("codex")
        let anthropicKey = Config.anthropicKey()
        let openAIKey = Config.openAIKey()

        switch preference {
        case "claude-cli":
            return claude.map { [claudeCLI(path: $0)] } ?? []
        case "anthropic-api":
            return anthropicKey.map { [anthropic(key: $0, model: settings.model)] } ?? []
        case "codex-cli":
            return codex.map { [codexCLI(path: $0, model: settings.openAIModel)] } ?? []
        case "openai-api":
            return openAIKey.map { [openAI(key: $0, model: settings.openAIModel)] } ?? []
        case "ollama":
            return [ollama(model: settings.ollamaModel)]
        default:
            var backends: [LLMBackend] = []
            if let claude { backends.append(claudeCLI(path: claude)) }
            if let anthropicKey {
                backends.append(anthropic(key: anthropicKey, model: settings.model))
            }
            if let codex { backends.append(codexCLI(path: codex, model: settings.openAIModel)) }
            if let openAIKey { backends.append(openAI(key: openAIKey, model: settings.openAIModel)) }
            backends.append(ollama(model: settings.ollamaModel))
            return backends
        }
    }

    // MARK: - Anthropic

    /// The CLI is handed an empty MCP config on purpose: this needs no tools,
    /// and without it the CLI starts every MCP server configured on the
    /// machine — minutes of startup for a one-shot prompt.
    private static func claudeCLI(path: String) -> LLMBackend {
        LLMBackend(name: "claude-cli") { system, prompt in
            try await run(
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

    private static func anthropic(key: String, model: String) -> LLMBackend {
        LLMBackend(name: "anthropic-api") { system, prompt in
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "max_tokens": 8000,
                "system": system,
                "messages": [["role": "user", "content": prompt]],
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw LLMError.http(http.statusCode, text(data))
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let content = json["content"] as? [[String: Any]]
            else { throw LLMError.malformedResponse("anthropic-api") }
            return content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
    }

    // MARK: - OpenAI

    /// `codex exec` prints a running trace to stdout, so the answer is read
    /// from the file it writes with `--output-last-message` rather than
    /// scraped out of the log.
    private static func codexCLI(path: String, model: String) -> LLMBackend {
        LLMBackend(name: "codex-cli") { system, prompt in
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("amanu-codex-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: output) }

            _ = try await run(
                executable: path,
                arguments: [
                    "exec",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--model", model,
                    "--output-last-message", output.path,
                    "-",
                ],
                input: "\(system)\n\n\(prompt)",
                timeout: 1800
            )
            guard let text = try? String(contentsOf: output, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LLMError.emptyResponse("codex-cli") }
            return text
        }
    }

    private static func openAI(key: String, model: String) -> LLMBackend {
        LLMBackend(name: "openai-api") { system, prompt in
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": prompt],
                ],
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // The API's own message names the problem — a model this
                // account can't see, a spent quota — and is worth reading
                // rather than paraphrasing.
                throw LLMError.http(http.statusCode, text(data))
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else { throw LLMError.malformedResponse("openai-api") }
            return content
        }
    }

    // MARK: - local

    private static func ollama(model: String) -> LLMBackend {
        LLMBackend(name: "ollama") { system, prompt in
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
                var response = json["response"] as? String
            else { throw LLMError.malformedResponse("ollama") }
            // Local reasoning models emit a thinking block before the answer.
            if let end = response.range(of: "</think>") {
                response = String(response[end.upperBound...])
            }
            return response
        }
    }

    // MARK: -

    static func cliPath(_ name: String) -> String? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/\(name)").path,
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data.prefix(400), as: UTF8.self)
    }

    /// Run a command with stdin, a deadline, and no shell in between.
    private static func run(
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
            throw LLMError.exit(
                Int(task.terminationStatus),
                String(decoding: err.prefix(600), as: UTF8.self)
                    + String(decoding: out.suffix(600), as: UTF8.self)
            )
        }
        return String(decoding: out, as: UTF8.self)
    }
}

enum LLMError: Error, CustomStringConvertible {
    case emptyResponse(String)
    case malformedResponse(String)
    case http(Int, String)
    case exit(Int, String)

    var description: String {
        switch self {
        case .emptyResponse(let backend): return "\(backend) returned nothing"
        case .malformedResponse(let backend): return "\(backend) returned an unexpected shape"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .exit(let code, let output): return "exited \(code): \(output)"
        }
    }

    /// Whether this failure is "the subscription or quota is spent" rather
    /// than something broken. Worth distinguishing in the log: falling through
    /// to the next backend is the expected, healthy path here, and reads as an
    /// error otherwise.
    var isUsageLimit: Bool {
        let haystack: String
        switch self {
        case .http(let code, let body):
            if code == 429 { return true }
            haystack = body.lowercased()
        case .exit(_, let output):
            haystack = output.lowercased()
        default:
            return false
        }
        return ["usage limit", "rate limit", "quota", "limit reached", "out of credit",
                "insufficient_quota", "429"].contains { haystack.contains($0) }
    }
}
