import Foundation
import Testing

@testable import amanu

/// Telling "come back to this later" apart from "this will never work".
///
/// The distinction decides whether a summary lost to a train tunnel is
/// retried that evening or written off, and whether a model that answered with
/// nonsense is asked the same question for ever.
struct LLMFailureTests {
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
