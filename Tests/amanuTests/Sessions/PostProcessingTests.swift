import Foundation
import Testing

@testable import amanu

/// The naming and summary passes against scripted models: which backend is
/// asked in which order, and what the session says afterwards when they fail.
///
/// The distinction under test is "come back to this" against "this will
/// never work". A summary written off on a plane is a meeting that never gets
/// one; a summary retried for ever against a model that answers nonsense is a
/// bill that never ends.
struct PostProcessingTests {
    private static let offline = URLError(.notConnectedToInternet)
    private static let refused = LLMError.http(401, "invalid x-api-key")

    /// Run `body` in a home whose models are `models`, in `auto` order.
    private static func withModels<R>(
        _ models: [FakeModel],
        config: [String: Any] = [:],
        _ body: () async throws -> R
    ) async throws -> R {
        let home = Home.withModels(models)
        defer { try? FileManager.default.removeItem(at: home.url) }
        var config = config
        config["user_name"] = "Самат"
        try home.writeConfig(config)
        return try await Home.$scoped.withValue(home) { try await body() }
    }

    private static func summarize(_ dir: URL, transcript: Transcript = SessionFixture.transcript)
        async -> String?
    {
        await Summarizer.summarize(transcript: transcript, context: [], into: dir)
    }

    private static func status(_ dir: URL, _ key: String) -> String? {
        SessionState.value(dir, key) as? String
    }

    // MARK: - summary

    @Test("The chain is walked in order and the first answer is kept")
    func fallbackOrder() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FakeModel("claude-cli", failing: Self.refused)
        let second = FakeModel("codex-cli", answer: "## Notes\nShipped.")
        let third = FakeModel("ollama", answer: "never asked")

        let winner = try await Self.withModels([first, second, third]) {
            await Self.summarize(dir)
        }

        #expect(winner == "codex-cli")
        let calls: [Int] = [first.callCount, second.callCount, third.callCount]
        #expect(calls == [1, 1, 0])
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
            == "## Notes\nShipped.\n")
        #expect(Self.status(dir, SessionState.Key.summaryStatus) == nil)
    }

    /// Re-transcription deleted summary.md before it knew whether a new
    /// transcript would ever exist, so a retry that failed for good cost the
    /// meeting its only summary.
    @Test("A summary remains current until a successful new transcript replaces it")
    func staleSummaryIsKeptUntilReplaced() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let summary = dir.appendingPathComponent("summary.md")
        try Data("## Old\nFrom the first transcript.\n".utf8).write(to: summary)
        let policy = PostProcessor.Policy(names: false, summary: true)
        let model = FakeModel("claude-cli", answer: "## New\nFrom the second transcript.")

        try await Self.withModels([model]) {
            PostProcessor.markForRetranscription(dir)

            #expect(FileManager.default.fileExists(atPath: summary.path),
                    "the only summary went before the retry had produced anything")
            #expect(PostProcessor.hasCurrentSummary(dir))
            let cleared = try #require(SessionInventory.item(for: dir, policy: policy))
            #expect(cleared.summary == .done, "the completed summary should remain available")
            #expect(PostProcessor.outstanding(dir, policy: policy).isEmpty,
                    "nothing to summarize until there is a transcript again")

            // The retry succeeds, and the summary owed is written over the old.
            try TranscriptVersions.commit(SessionFixture.transcript, to: dir)
            #expect(PostProcessor.outstanding(dir, policy: policy).summary)
            await PostProcessor.finish(dir, policy: policy)
        }

        #expect(model.callCount == 1)
        #expect(try String(contentsOf: summary, encoding: .utf8)
            == "## New\nFrom the second transcript.\n")
        #expect(PostProcessor.hasCurrentSummary(dir))
        #expect(SessionState.value(dir, SessionState.Key.summaryStale) == nil)
        #expect(SessionInventory.item(for: dir, policy: policy)?.summary == .done)
    }

    @Test("An unreachable backend hands over to the next one, which writes the summary")
    func transientThenSuccess() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionState.update(dir, with: [SessionState.Key.summaryStatus: SessionState.deferred])

        let winner = try await Self.withModels([
            FakeModel("claude-cli", failing: Self.offline),
            FakeModel("ollama", answer: "## Notes"),
        ]) { await Self.summarize(dir) }

        #expect(winner == "ollama")
        #expect(Self.status(dir, SessionState.Key.summaryStatus) == nil)
    }

    @Test("Every backend unreachable: the summary is deferred and still owed")
    func allTransientDefers() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let models = [
            FakeModel("claude-cli", failing: Self.offline),
            FakeModel("ollama", failing: NSError(domain: NSPOSIXErrorDomain, code: 61)),
        ]

        try await Self.withModels(models) {
            #expect(await Self.summarize(dir) == nil)
            #expect(Self.status(dir, SessionState.Key.summaryStatus) == SessionState.deferred)
            #expect(PostProcessor.outstanding(
                dir, policy: .init(names: false, summary: true)).summary)
        }
    }

    /// The case that used to write a summary off for good: one backend that
    /// answered badly and one that was merely offline. The offline one may
    /// well answer this evening.
    @Test("One backend failing for good and another merely offline defers, in either order")
    func mixedFailuresDefer() async throws {
        for order in [[Self.refused, Self.offline] as [any Error], [Self.offline, Self.refused]] {
            let dir = try SessionFixture.make()
            defer { try? FileManager.default.removeItem(at: dir) }
            try await Self.withModels([
                FakeModel("claude-cli", failing: order[0]),
                FakeModel("ollama", failing: order[1]),
            ]) {
                #expect(await Self.summarize(dir) == nil)
            }
            #expect(Self.status(dir, SessionState.Key.summaryStatus) == SessionState.deferred)
            #expect(SessionState.value(dir, SessionState.Key.summaryFailedFor) == nil)
        }
    }

    @Test("An empty answer is a failure, and the next backend is asked")
    func emptyAnswerFallsThrough() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let winner = try await Self.withModels([
            FakeModel("claude-cli", answer: "  \n "),
            FakeModel("ollama", answer: "## Notes"),
        ]) { await Self.summarize(dir) }
        #expect(winner == "ollama")
    }

    /// A failure is final only for the configuration it happened under. The
    /// rule: the session records a fingerprint of the settings, keys and
    /// backends beside `failed`, and is offered again once that changes.
    @Test("Every backend failing for good gives up — until the configuration changes")
    func permanentFailureIsRetriedAfterAConfigChange() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = PostProcessor.Policy(names: false, summary: true)
        let home = Home.withModels([FakeModel("claude-cli", failing: Self.refused)])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "auto"]])

        try await Home.$scoped.withValue(home) {
            #expect(await Self.summarize(dir) == nil)
            #expect(Self.status(dir, SessionState.Key.summaryStatus) == SessionState.failed)
            #expect(SessionState.value(dir, SessionState.Key.summaryFailedFor) is String)
            #expect(!PostProcessor.outstanding(dir, policy: policy).summary,
                    "Nothing has changed, so asking again would get the same answer.")

            try home.writeConfig(["summary": ["backend": "auto", "model": "claude-sonnet-5"]])
            #expect(PostProcessor.outstanding(dir, policy: policy).summary,
                    "A new model is a new question.")
        }
    }

    @Test("A failure recorded before there were fingerprints stays given up")
    func aLegacyFailureStaysGivenUp() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionState.update(dir, with: [SessionState.Key.summaryStatus: "failed"])
        #expect(!PostProcessor.outstanding(dir, policy: .init(names: false, summary: true)).summary)
    }

    @Test("A long meeting is summarized in parts and the parts are merged")
    func chunkedSummaryMerges() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Three parts' worth of lines, each well under a part on its own.
        let line = String(repeating: "обсудили план ", count: 40)
        let long = Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-01T10:00:00Z",
            segments: (0..<300).map {
                .init(speaker: $0.isMultiple(of: 2) ? "me" : "them", start_ms: $0 * 1000,
                      end_ms: $0 * 1000 + 900, text: line)
            })
        let model = FakeModel("claude-cli") { _, _, prompt in
            prompt.contains("Combine them into one note") ? "MERGED" : "part notes"
        }

        let winner = try await Self.withModels([model]) {
            await Self.summarize(dir, transcript: long)
        }

        #expect(winner == "claude-cli")
        let prompts = model.prompts
        #expect(prompts.count >= 3)
        #expect(prompts.dropLast().allSatisfy { $0.contains("Part ") })
        #expect(prompts.last?.contains("part notes\n\n---\n\npart notes") == true)
        #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
            == "MERGED\n")
    }

    // MARK: - naming

    private static func name(_ dir: URL) async -> SpeakerNames? {
        await SpeakerNamer.name(
            transcript: SessionFixture.transcript, title: nil, attendees: [], app: nil, into: dir)
    }

    @Test("A garbage mapping falls through to the next backend, whose names are kept")
    func garbageNamingAnswerFallsThrough() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try await Self.withModels([
            FakeModel("claude-cli", answer: "I think them A is probably Fyodor."),
            FakeModel("codex-cli", answer: SessionFixture.namesThemA),
        ]) { await Self.name(dir) }

        #expect(names?.speakers["them A"]?.name == "Фёдор")
        #expect(names?.backend == "codex-cli")
        #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.name == "Самат")
    }

    @Test("Naming defers when any backend was unreachable, and gives up only when none was")
    func namingDeferral() async throws {
        let cases: [([any Error], String)] = [
            ([Self.offline, Self.offline], SessionState.deferred),
            ([Self.refused, Self.offline], SessionState.deferred),
            ([Self.refused, Self.refused], SessionState.failed),
        ]
        for (errors, expected) in cases {
            let dir = try SessionFixture.make()
            defer { try? FileManager.default.removeItem(at: dir) }
            let names = try await Self.withModels([
                FakeModel("claude-cli", failing: errors[0]),
                FakeModel("ollama", failing: errors[1]),
            ]) { await Self.name(dir) }
            #expect(names == nil)
            #expect(Self.status(dir, SessionState.Key.speakersStatus) == expected)
        }
    }

    @Test("A timestamp written as a string or a fraction does not cost the names")
    func atMsIsReadLeniently() throws {
        let proposals = try SpeakerNamer.parse("""
        {"speakers": [
          {"label": "them A", "name": "Фёдор", "confidence": "high",
           "quote": "Фёдор, слышно меня?", "at_ms": "3000"},
          {"label": "them B", "name": null, "confidence": "low", "quote": null,
           "at_ms": 6000.0},
          {"label": "me", "name": "Самат", "confidence": "high", "quote": "Привет! Фёдор",
           "at_ms": 1e40}
        ]}
        """)
        #expect(proposals.map(\.at_ms) == [3000, 6000, nil])
        #expect(proposals.first?.name == "Фёдор")
    }

    // MARK: - what counts as offline

    @Test("The CLIs' own words for being offline are transient")
    func offlineCLIOutputIsTransient() {
        #expect(LLMError.exit(1, "API Error: Connection error.").isTransient)
        #expect(LLMError.exit(1, "API Error (Connection error.) · Retrying in 1 seconds…")
            .isTransient)
        #expect(LLMError.exit(1, "getaddrinfo ENOTFOUND api.anthropic.com").isTransient)
        #expect(LLMError.exit(
            1, "stream error: error sending request for url (https://api.openai.com/v1/responses)"
        ).isTransient)
        #expect(!LLMError.exit(1, "Invalid API key · Please run /login").isTransient)
    }
}
