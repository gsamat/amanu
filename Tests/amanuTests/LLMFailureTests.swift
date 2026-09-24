import Foundation
import Testing

@testable import amanu

/// Telling "come back to this later" apart from "this will never work".
///
/// The distinction decides whether a summary lost to a train tunnel is
/// retried that evening or written off, and whether a model that answered with
/// nonsense is asked the same question for ever.
struct LLMFailureTests {
    @Test("The configured summary template is the instruction sent with the transcript")
    func customSummaryTemplateBuildsThePrompt() {
        let prompt = Summarizer.singlePassPrompt(
            body: "me: We approved the launch.",
            header: "Meeting: Launch review\n",
            template: "## Decisions\nList only decisions.")

        #expect(prompt.contains("## Decisions\nList only decisions."))
        #expect(prompt.contains("Meeting: Launch review"))
        #expect(prompt.hasSuffix("me: We approved the launch."))
        #expect(!prompt.contains("## What this was about"))
    }

    @Test("OpenAI-compatible endpoints preserve a base path and avoid double slashes")
    func compatibleAPIEndpoint() {
        #expect(OpenAICompatible.endpoint(
            baseURL: "https://llm.example/openai/v1/", path: "chat/completions")?
            .absoluteString == "https://llm.example/openai/v1/chat/completions")
        #expect(OpenAICompatible.endpoint(baseURL: "not a url", path: "models") == nil)
    }

    @Test("A spent allowance is transient — it comes back")
    func usageLimitIsTransient() {
        let cli = LLMError.exit(1, "Claude usage limit reached. Resets at 5pm.")
        #expect(cli.isUsageLimit)
        #expect(cli.isTransient)

        let http = LLMError.http(429, "rate_limit_error")
        #expect(http.isUsageLimit)
        #expect(http.isTransient)
    }

    @Test("A server that fell over is transient; a rejected request is not")
    func serverErrorsVersusClientErrors() {
        #expect(LLMError.http(503, "service unavailable").isTransient)
        #expect(LLMError.http(500, "internal error").isTransient)
        #expect(!LLMError.http(401, "invalid x-api-key").isTransient)
        #expect(!LLMError.http(404, "model not found").isTransient)
    }

    /// ollama is the offline floor of the chain, and "not running" is exactly
    /// the case where retrying later is right.
    @Test("A local model that isn't running yet is transient")
    func connectionRefusedIsTransient() {
        #expect(LLMError.exit(1, "curl: (7) Failed to connect: Connection refused").isTransient)
        #expect(LLMError.isTransient(
            NSError(domain: NSPOSIXErrorDomain, code: 61)))  // ECONNREFUSED
        #expect(LLMError.isTransient(URLError(.notConnectedToInternet)))
        #expect(LLMError.isTransient(URLError(.timedOut)))
    }

    /// A subscription CLI that has signed itself out is back the next time
    /// its owner uses it for anything else, so a summary lost to it must be
    /// deferred rather than written off. The strings are the ones the
    /// binaries print.
    @Test("A signed-out CLI is transient, and is reported as a missing credential")
    func signedOutCLIIsTransient() {
        let signedOut = [
            "Failed to authenticate: OAuth session expired and could not be refreshed",
            "API Error: 401 Invalid API key · Please run /login",
            "Not logged in",
            "ERROR: Your access token could not be refreshed. Please log out and sign in again.",
        ]
        for output in signedOut {
            let error = LLMError.exit(1, output)
            #expect(error.isSignedOut, "\(output)")
            #expect(error.isTransient, "\(output)")
            #expect(!error.isUsageLimit, "\(output)")
            #expect(Analytics.reason(for: error) == .noKey, "\(output)")
        }

        // A key the API refuses stays refused until somebody replaces it.
        #expect(!LLMError.http(401, "invalid x-api-key").isSignedOut)
        #expect(!LLMError.exit(1, "The 'gpt-5' model is not supported").isSignedOut)
    }

    /// `codex exec` writes a banner, then its whole input, then the error.
    @Test("A failed command is described by how it ended, not by its echo of the prompt")
    func failureTextKeepsTheEndAndDropsTheEcho() {
        let prompt = "You are taking notes.\n\n"
            + String(repeating: "them: we are over quota on the staging cluster\n", count: 200)
        let stderr = "OpenAI Codex v0.156.1\n--------\nmodel: gpt-5\n--------\nuser\n"
            + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            + "hook: SessionStart\n"
            + #"ERROR: {"status":400,"message":"The 'gpt-5' model is not supported."}"# + "\n"

        let text = LLMBackend.failureText(
            stderr: Data(stderr.utf8), stdout: Data(), input: prompt)

        #expect(text.contains("The 'gpt-5' model is not supported."))
        #expect(!text.contains("staging cluster"))
        // The meeting talked about a quota; the backend never ran out of one.
        #expect(!LLMError.exit(1, text).isUsageLimit)
        #expect(!LLMError.exit(1, text).isTransient)
    }

    @Test("A long failure is cut from the front, at a line")
    func failureTextKeepsTheTail() {
        let stderr = (1...200).map { "trace line \($0)" }.joined(separator: "\n")
            + "\nfatal: the actual reason"
        let text = LLMBackend.failureText(
            stderr: Data(stderr.utf8), stdout: Data(), input: "")

        #expect(text.hasPrefix("…trace line "))
        #expect(text.hasSuffix("fatal: the actual reason"))
        #expect(text.count <= 1001)
        #expect(!text.contains("trace line 1\n"))
    }

    /// The model answered — it just answered badly. Repeating the same request
    /// won't change that, and retrying for ever is how a session never settles.
    @Test("A bad answer is permanent, not transient")
    func badAnswersAreNotRetried() {
        #expect(!LLMError.emptyResponse("claude-cli").isTransient)
        #expect(!LLMError.malformedResponse("openai-api").isTransient)
        #expect(!LLMError.isTransient(URLError(.badURL)))
        #expect(!LLMError.isTransient(NSError(domain: "SomeOtherDomain", code: 61)))
    }

    @Test("A deferred summary is recorded so a later pass can pick it up")
    func deferredStateRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["stop_reason": "manual"])
            .write(to: dir.appendingPathComponent("meta.json"))

        SessionState.update(dir, with: [SessionState.Key.summaryStatus: SessionState.deferred])
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String == "deferred")
        // Untouched keys survive the merge.
        #expect(SessionState.value(dir, "stop_reason") as? String == "manual")

        // nil clears — a state that no longer applies must not linger as a
        // stale claim that something still needs doing.
        SessionState.update(dir, with: [SessionState.Key.summaryStatus: nil])
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) == nil)
        #expect(SessionState.value(dir, "stop_reason") as? String == "manual")
    }
}
