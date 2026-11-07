import Foundation
import Testing

@testable import amanu

struct SpeakerReviewTests {
    @Test("Handler tokens clean up their owner without unregistering a newer desktop")
    func handlerOwnershipFollowsTokens() {
        let registry = SpeakerReview.HandlerRegistry()
        var first: SpeakerReview.HandlerToken? = registry.register { _ in }
        weak var firstLifetime = first
        #expect(registry.current != nil)
        var second: SpeakerReview.HandlerToken? = registry.register { _ in }
        weak var secondLifetime = second
        first = nil
        #expect(firstLifetime == nil)
        #expect(registry.current != nil, "The old owner's deinit must not remove the new callback")
        second = nil
        #expect(secondLifetime == nil)
        #expect(registry.current == nil, "No dead desktop callback may continue offering review")
    }

    private func withModels<R>(_ models: [FakeModel], keepAudio: Bool = false,
                               _ body: () async throws -> R) async throws -> R {
        let home = Home.withModels(models)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["keep_audio": keepAudio, "offline_echo_cancellation": false,
                              "summary": ["backend": "auto"]])
        return try await Home.$scoped.withValue(home) {
            try await SpeakerReview.$usesInstalledHandler.withValue(false) { try await body() }
        }
    }

    private func session() throws -> URL {
        let dir = try SessionFixture.make(meta: ["files": ["source": "source.m4a"]])
        try Data("retained audio".utf8).write(to: dir.appendingPathComponent("source.m4a"))
        try SpeakerReview.recordTranscript(dir, supportsDiarization: true)
        StopHook.owe(dir)
        return dir
    }

    @Test("An interactive review protects its audio and blocks sweep/CLI and hooks until the choice")
    func interactiveReviewProtectsWork() async throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel("claude-cli", answer: "## Reviewed\nReady.")
        try await withModels([model]) {
            try await SpeakerReview.$scopedHandler.withValue({ _ in }) {
                let work = await PostProcessor.finish(dir)
                #expect(work.review)
                #expect(SessionClaim.holder(dir)?.stage == "review")
                #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.m4a").path))
                #expect(!StopHook.fireIfOwed(dir, command: nil))
                #expect(await PostProcessor.finish(dir) == PostProcessor.Work())
                #expect(model.callCount == 0)
                // The same entered name survives either UI action (including Skip).
                PostProcessor.rename("them A", to: "Мария", in: dir)
                try SpeakerReview.complete(dir)
                #expect(!SessionClaim.isHeld(dir))
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.m4a").path))
                _ = await PostProcessor.finish(dir)
                #expect(model.callCount == 1)
                #expect(model.prompts.first?.contains("Мария") == true)
                #expect(SpeakerNames.read(from: dir)?.name(for: "them A") == "Мария")
            }
        }
    }

    @Test("Waiting for two reviews does not block the serial transcription queue")
    func multipleReviewsDoNotBlockASR() async throws {
        let first = try TestAudio.rawSession(postProcessing: true)
        let second = try TestAudio.rawSession(postProcessing: true)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let model = FakeModel("claude-cli", answer: "Must wait for the human")
        try await withModels([model]) {
            try await SpeakerReview.$scopedHandler.withValue({ _ in }) {
                let engine = FakeEngine("assemblyai", input: .mixed, answer: { _, _ in [
                    .init(start: 0, end: 0.5, text: "First voice", speaker: "A"),
                    .init(start: 0.5, end: 1, text: "Second voice", speaker: "B"),
                ] })
                let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
                await coordinator.enqueue(first)
                await coordinator.enqueue(second)
                await coordinator.waitUntilIdle()
                #expect(engine.counts.heard.count == 2)
                #expect(SessionClaim.holder(first)?.stage == "review")
                #expect(SessionClaim.holder(second)?.stage == "review")
                #expect(model.callCount == 0)
                try SpeakerReview.complete(first)
                try SpeakerReview.complete(second)
            }
        }
    }

    @Test("A CLI cannot skip a live desktop review during the ASR-to-review handoff")
    func liveOwnerProtectsHandoff() async throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        try SessionState.amend(dir, with: [SessionState.Key.speakerReview: [
            "transcript": try #require(SpeakerReview.transcriptID(dir)), "state": "ready",
            "owner_pid": other.processIdentifier, "interactive": true,
        ]])
        let model = FakeModel("claude-cli", answer: "Must not run")
        try await withModels([model]) {
            #expect(await PostProcessor.finish(dir) == PostProcessor.Work())
            #expect(SpeakerReview.isPending(dir))
            #expect(model.callCount == 0)
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.m4a").path))
        }
    }

    @Test("Headless processing skips naming, honors retention, and completes the summary")
    func headlessSkipKeepsAudioWhenConfigured() async throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FakeModel("claude-cli", answer: "## Headless\nDone.")
        try await withModels([model], keepAudio: true) {
            _ = await PostProcessor.finish(dir)
            #expect(SpeakerReview.hasDecision(dir))
            #expect(!SpeakerReview.isPending(dir))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.m4a").path))
            #expect(model.callCount == 1)
            #expect(PostProcessor.hasCurrentSummary(dir))
        }
    }

    @Test("A dead review owner is recovered by skipping, never by presenting the old review again")
    func recoverySkipsDeadOwner() async throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(SpeakerReview.transcriptID(dir))
        try SessionState.amend(dir, with: [SessionState.Key.speakerReview: [
            "transcript": id, "state": "reviewing", "owner_pid": 999_999,
        ]])
        try JSONSerialization.data(withJSONObject: ["pid": 999_999, "stage": "review"])
            .write(to: SessionClaim.url(dir))
        let model = FakeModel("claude-cli", answer: "## Recovered\nDone.")
        try await withModels([model]) {
            await SpeakerReview.$scopedHandler.withValue({ _ in Issue.record("Recovery must not offer UI") }) {
                _ = await PostProcessor.finish(dir)
            }
            #expect(SpeakerReview.hasDecision(dir))
            #expect(!SpeakerReview.isPending(dir))
            #expect(model.callCount == 1)
            #expect(!SessionClaim.isHeld(dir))
        }
    }

    @Test("Track-only engines never offer review, and diarized me/them remain eligible")
    func capabilityNotLabelSpelling() async throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "one"),
            .init(speaker: "them", start_ms: 1000, end_ms: 2000, text: "two"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        try SpeakerReview.recordTranscript(dir, supportsDiarization: false)
        #expect(!SpeakerReview.isPending(dir))
        try SpeakerReview.recordTranscript(dir, supportsDiarization: true)
        #expect(SpeakerReview.isPending(dir))
    }

    @Test("Review offers a local owner suggestion only for exact me, preserving manual entries")
    func localOwnerSuggestion() async throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "one"),
            .init(speaker: "me A", start_ms: 1000, end_ms: 2000, text: "two"),
            .init(speaker: "me B", start_ms: 2000, end_ms: 3000, text: "three"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home.withModels([])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["user_name": "Ольга", "keep_audio": true])
        try await Home.$scoped.withValue(home) {
            try SpeakerReview.recordTranscript(dir, supportsDiarization: true)
            try await SpeakerReview.$scopedHandler.withValue({ _ in }) {
                _ = await PostProcessor.finish(dir, policy: .init(names: false, summary: true))
                let names = try #require(SpeakerNames.read(from: dir))
                #expect(names.speakers["me"]?.name == "Ольга")
                #expect(names.speakers["me"]?.source == .config)
                #expect(names.speakers["me A"] == nil)
                #expect(names.speakers["me B"] == nil)
                PostProcessor.rename("me", to: "Личное имя", in: dir)
                try SpeakerReview.complete(dir)
                #expect(SpeakerNames.read(from: dir)?.speakers["me"]?.name == "Личное имя")
            }
        }
    }

    @Test("Names entered for a new ASR refresh the retained old summary after confirmation")
    func reviewedRetranscriptionReplacesOldSummary() async throws {
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("Previous ASR summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        try SessionState.amend(dir, with: [SessionState.Key.summaryStale: true])
        let model = FakeModel("claude-cli", answer: "## New ASR\nReviewed names.")
        try await withModels([model]) {
            try await SpeakerReview.$scopedHandler.withValue({ _ in }) {
                _ = await PostProcessor.finish(dir)
                PostProcessor.rename("them A", to: "Мария", in: dir)
                #expect(!PostProcessor.summaryNeedsManualUpdate(dir))
                try SpeakerReview.complete(dir)
                _ = await PostProcessor.finish(dir)
                #expect(model.callCount == 1)
                #expect(PostProcessor.hasCurrentSummary(dir))
                #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)
                    == "## New ASR\nReviewed names.\n")
            }
        }
    }

    @Test("Renaming keeps the old summary and requires an explicit refresh, including during generation")
    func manualSummaryRefresh() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("Old summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let model = FakeModel("claude-cli", answer: "## New\nCurrent names.")
        try await withModels([model]) {
            PostProcessor.rename("them A", to: "Мария", in: dir)
            #expect(PostProcessor.summaryNeedsManualUpdate(dir))
            #expect(!PostProcessor.hasCurrentSummary(dir))
            #expect(!PostProcessor.outstanding(dir, policy: .init(names: false, summary: true)).summary)
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) == "Old summary")
            try PostProcessor.requestSummaryUpdate(dir)
            _ = await PostProcessor.finish(dir, policy: .init(names: false, summary: true))
            #expect(model.callCount == 1)
            #expect(!PostProcessor.summaryNeedsManualUpdate(dir))
            #expect(PostProcessor.hasCurrentSummary(dir))
        }
        let changing = FakeModel("claude-cli") { _, _, _ in
            PostProcessor.rename("them A", to: "Анна", in: dir)
            return "Wrong snapshot"
        }
        try await withModels([changing]) {
            try PostProcessor.requestSummaryUpdate(dir)
            // Force a request even while the existing summary is current.
            try SessionState.amend(dir, with: [SessionState.Key.summaryStale: true])
            _ = await PostProcessor.finish(dir, policy: .init(names: false, summary: true))
            #expect(try String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) != "Wrong snapshot\n")
            #expect(PostProcessor.summaryNeedsManualUpdate(dir))
        }
    }

    @Test("Audio previews use archive time, subtract raw track offsets, and bound both clips")
    func audioPreviewCoordinates() throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "them A", start_ms: 2500, end_ms: 4000, text: "First."),
            .init(speaker: "them A", start_ms: 6000, end_ms: 18000, text: "The longest example for identifying this speaker."),
        ], meta: ["files": ["system": "system.caf"], "start_offset_ms": ["system": 500]])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("system.caf"))
        let transcript = try #require(PostProcessor.readTranscript(dir))
        let sample = try #require(SessionInventory.samples(transcript: transcript, names: nil).first)
        let raw = SpeakerReview.audioSamples(for: sample, in: dir)
        #expect(raw.count == 2)
        #expect(raw[0].start == 2)
        #expect(raw[1].start == 5.5)
        #expect(raw[1].end == 13.5)
        try Data().write(to: dir.appendingPathComponent("audio.m4a"))
        try SessionState.amend(dir, with: ["files": ["mic": "audio.m4a", "system": "audio.m4a"],
                                          "start_offset_ms": ["mic": 0, "system": 0],
                                          "audio_channels": ["mic": 0, "system": 1]])
        let archived = SpeakerReview.audioSamples(for: sample, in: dir)
        #expect(archived[0].start == 2.5)
        #expect(archived[1].start == 6)
    }

    @Test("A voice attribution could not place still has a clip when compression left two tracks")
    func unplacedVoiceOnSeparateTracks() throws {
        let dir = try SessionFixture.make(segments: [
            .init(speaker: "A", start_ms: 0, end_ms: 1000, text: "Hello."),
            .init(speaker: "A", start_ms: 1000, end_ms: 2500, text: "The longer turn of the same voice."),
            .init(speaker: "B", start_ms: 2500, end_ms: 3000, text: "Hi."),
        ], meta: ["files": ["mic": "mic.caf", "system": "system.caf"],
                  "start_offset_ms": ["mic": 0, "system": 500]])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Preparing controls must not open or decode the source files.
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        try Data().write(to: dir.appendingPathComponent("system.caf"))
        let transcript = try #require(PostProcessor.readTranscript(dir))
        let sample = try #require(SessionInventory.samples(transcript: transcript, names: nil).first)
        #expect(sample.label == "A")
        let clips = SpeakerReview.audioSamples(for: sample, in: dir)
        #expect(clips.count == 2)
        let first = try #require(clips.first)
        #expect(first.sources.map { $0.file.lastPathComponent } == ["mic.caf", "system.caf"])
        #expect(first.sources.map(\.start) == [0, 0])
        #expect(first.sources.map(\.delay) == [0, 0.5])
        let longest = try #require(clips.last)
        #expect(longest.sources.map(\.start) == [1, 0.5])
        #expect(longest.sources.map(\.delay) == [0, 0])

        // The mix the engine heard, when it is still in the folder, is preferred.
        try Data().write(to: dir.appendingPathComponent(TranscriptionInputs.mixedFile))
        #expect(SpeakerReview.audioSamples(for: sample, in: dir)
            .allSatisfy { $0.file.lastPathComponent == TranscriptionInputs.mixedFile })
    }

    @Test("An unreadable transcript cannot silently skip speaker review")
    func missingOrInvalidTranscriptFailsReviewRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try SpeakerReview.pendingRecord(dir, supportsDiarization: true)
        }
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        #expect(throws: (any Error).self) {
            try SpeakerReview.pendingRecord(dir, supportsDiarization: true)
        }
    }

    @Test("A diarized first transcript publishes its review with it, or not at all")
    func firstTranscriptCarriesItsReview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONSerialization.data(withJSONObject: ["files": ["source": "source.m4a"]])
            .write(to: dir.appendingPathComponent("meta.json"))
        try TranscriptVersions.commit(SessionFixture.transcript, to: dir, supportsDiarization: true)
        #expect(SpeakerReview.isPending(dir))

        // meta.json that can't be amended: the transcript must not be left
        // behind as a completion marker without the review that belongs to it.
        for file in ["transcript.json", "transcript.md"] {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
        try Data("{".utf8).write(to: dir.appendingPathComponent("meta.json"))
        #expect(throws: (any Error).self) {
            try TranscriptVersions.commit(SessionFixture.transcript, to: dir, supportsDiarization: true)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    @Test("A re-transcription publishes its review in the same step that replaces the transcript")
    func retranscriptionCarriesItsReview() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PostProcessor.markForRetranscription(dir))
        try TranscriptVersions.commit(Transcript(engine: "compatible", model: "new", created_at: "2026-11-06T12:00:00Z",
            segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: "One voice."),
                       .init(speaker: "B", start_ms: 1000, end_ms: 2000, text: "Another voice.")]),
            to: dir, supportsDiarization: true)
        #expect(!TranscriptVersions.isRequested(dir))
        #expect(SpeakerReview.isPending(dir))
        #expect(PostProcessor.outstanding(dir, policy: .init(names: true, summary: true)) == .init(review: true))
    }

    @Test("A meta.json write that fails after the new transcript is written restores the old result and request")
    func retranscriptionRollsBackWhenMetaCannotBeWritten() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        PostProcessor.rename("them A", to: "Мария", in: dir)
        #expect(PostProcessor.markForRetranscription(dir))
        let oldID = try #require(SpeakerReview.transcriptID(dir))
        let kept = ["transcript.json", "transcript.md", SpeakerNames.file]
        var before: [String: Data] = [:]
        for name in kept { before[name] = try Data(contentsOf: dir.appendingPathComponent(name)) }
        // Unparsable meta.json lets the snapshot, the removal of the old
        // anonymous names and the new transcript's write all succeed; the one
        // amend that publishes them, the review included, is what fails.
        let brokenMeta = Data("{".utf8)
        try brokenMeta.write(to: dir.appendingPathComponent("meta.json"))
        let replacement = Transcript(engine: "compatible", model: "new", created_at: "2026-11-06T12:00:00Z",
            segments: [.init(speaker: "A", start_ms: 0, end_ms: 1000, text: "One voice."),
                       .init(speaker: "B", start_ms: 1000, end_ms: 2000, text: "Another voice.")])
        #expect(throws: (any Error).self) {
            try TranscriptVersions.commit(replacement, to: dir, supportsDiarization: true)
        }
        for name in kept {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == before[name], "\(name) not restored")
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("meta.json")) == brokenMeta)
        #expect(TranscriptVersions.isRequested(dir), "The request survives for another attempt")
        #expect(SpeakerReview.transcriptID(dir) == oldID)
        // The snapshot taken first is harmless: it is the current result, so it
        // is neither lost nor listed a second time.
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcripts").appendingPathComponent(oldID).path))
        #expect(TranscriptVersions.read(dir).filter { !$0.isRequest }.count == 1)
    }

    @Test("A new ASR never inherits an anonymous voice's manual name or review decision")
    func newTranscriptResetsAnonymousNames() throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        PostProcessor.rename("them A", to: "Мария", in: dir)
        try SpeakerReview.recordTranscript(dir, supportsDiarization: true)
        #expect(PostProcessor.markForRetranscription(dir))
        try TranscriptVersions.commit(Transcript(engine: "compatible", model: "new", created_at: "2026-11-06T12:00:00Z",
            segments: [.init(speaker: "them A", start_ms: 0, end_ms: 2000, text: "A different person's voice")]), to: dir)
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"] == nil)
        #expect(!SpeakerReview.isPending(dir))
        #expect(!SpeakerReview.hasDecision(dir))
    }

    @Test("Cancellation keeps audio and does not charge an attempt in direct or queued processing")
    func cancellationIsNotAFailure() async throws {
        let direct = try TestAudio.rawSession()
        let queued = try TestAudio.rawSession()
        defer {
            try? FileManager.default.removeItem(at: direct)
            try? FileManager.default.removeItem(at: queued)
        }
        try await withModels([]) {
            let cancelled = FakeEngine("parakeet", answer: { _, _ in throw CancellationError() })
            let coordinator = TranscriptionCoordinator(engine: cancelled, onStop: { nil })
            await #expect(throws: CancellationError.self) { try await coordinator.transcribeNow(direct) }
            await coordinator.enqueue(queued)
            await coordinator.waitUntilIdle()
            for dir in [direct, queued] {
                #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
                #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
                #expect(!SessionClaim.isHeld(dir))
                #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
            }
        }
    }
}
