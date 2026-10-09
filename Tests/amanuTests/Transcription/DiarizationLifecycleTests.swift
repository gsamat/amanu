import Foundation
import Testing
import os
import ArgumentParser
@testable import amanu

@Suite(.freshHome(config: #"{"offline_echo_cancellation":false,"transcription":{"local_diarization":true},"speaker_names":{"enabled":false},"summary":{"enabled":false}}"#))
struct DiarizationLifecycleTests {
    private actor FaultRuntime: LocalDiarizationRuntime {
        struct Failed: Error {}
        private var calls = 0
        private let failures: Int

        init(failures: Int) { self.failures = failures }
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            calls += 1
            if calls <= failures { throw Failed() }
            return [SpeakerTurn(speakerID: "voice", start: 0, end: 1)]
        }
        func release() async {}
        func count() -> Int { calls }
    }

    private actor SilenceRuntime: LocalDiarizationRuntime {
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            throw LocalDiarizationRuntimeError.noSpeechDetected
        }
        func release() async {}
    }

    private actor UnavailableRuntime: LocalDiarizationRuntime {
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            throw LocalDiarizationRuntimeError.unavailable
        }
        func release() async {}
    }

    private actor FailSecondRuntime: LocalDiarizationRuntime {
        struct Failed: Error {}
        private var calls = 0
        func prepare() async throws {}
        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            calls += 1
            if calls == 2 { throw Failed() }
            return [SpeakerTurn(speakerID: "remote", start: 0, end: 1)]
        }
        func release() async {}
        func count() -> Int { calls }
    }

    private final class OptionsEngine: TranscriptionEngine {
        let wrapped: FakeEngine
        let optionsFingerprint: String
        init(wrapped: FakeEngine, optionsFingerprint: String) {
            self.wrapped = wrapped
            self.optionsFingerprint = optionsFingerprint
        }
        var name: String { wrapped.name }
        var model: String { wrapped.model }
        var input: TranscriptionInput { wrapped.input }
        func prepare() async throws { try await wrapped.prepare() }
        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            try await wrapped.transcribe(audio)
        }
        func release() async { await wrapped.release() }
    }

    private static func wordEngine(
        prepareError: (@Sendable () -> Error?)? = nil
    ) -> FakeEngine {
        FakeEngine("parakeet", prepareError: prepareError, answer: { audio, _ in
            if audio.lastPathComponent == "mic.caf" {
                return [TranscriptSegment(start: 0, end: 1, text: "local",
                    words: [TranscriptWord(start: 0, end: 1, text: "local")])]
            }
            return [TranscriptSegment(start: 0, end: 1, text: "remote",
                words: [TranscriptWord(start: 0, end: 1, text: "remote")])]
        })
    }

    @Test("An inference fault preserves provisional text and audio; retry reuses ASR")
    func inferenceFaultThenRetry() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("retry")
        let hookLog = recordings.root.appendingPathComponent("hook.log")
        let hookScript = recordings.root.appendingPathComponent("hook.sh")
        try Data("#!/bin/sh\nprintf 'once\\n' >> '\(hookLog.path)'\n".utf8)
            .write(to: hookScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
            ofItemAtPath: hookScript.path)
        let modelRemoved = OSAllocatedUnfairLock(initialState: false)
        let engine = Self.wordEngine(prepareError: {
            modelRemoved.withLock { $0 ? CocoaError(.fileReadNoSuchFile) : nil }
        })
        let runtime = FaultRuntime(failures: 1)
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { hookScript.path },
            diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })

        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.status == .pending)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        #expect(PostProcessor.readTranscript(dir)?.segments.contains { $0.speaker == "them" } == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization-source-them.caf").path))
        #expect(DiarizationArtifacts.readASR(dir)?.tracks.count == 2)
        let recognized = engine.counts.heard.count
        let preparations = engine.counts.prepared
        modelRemoved.withLock { $0 = true }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: hookLog.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((try? String(contentsOf: hookLog, encoding: .utf8)) == "once\n")

        try await coordinator.diarizeNow(dir)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(await runtime.count() == 2)
        #expect(engine.counts.heard.count == recognized)
        #expect(engine.counts.prepared == preparations)
        #expect(PostProcessor.readTranscript(dir)?.segments.contains { $0.speaker == "them" } == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization-source-them.caf").path))
        #expect(TranscriptVersions.read(dir).count == 2)
        try await coordinator.diarizeNow(dir)
        #expect(await runtime.count() == 2)
        #expect(TranscriptVersions.read(dir).count == 2)
        #expect((try? String(contentsOf: hookLog, encoding: .utf8)) == "once\n")
    }

    @Test("An inference failure does not prevent the next queued session")
    func queueContinuesAfterInferenceFault() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let first = try recordings.session("a")
        let second = try recordings.session("b")
        let runtime = FaultRuntime(failures: 1)
        let coordinator = TranscriptionCoordinator(
            engine: Self.wordEngine(), diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })

        await coordinator.drainPending(in: recordings.root)

        #expect(DiarizationState.read(first)?.status == .pending)
        #expect(DiarizationState.read(second)?.status == .completed)
        #expect(await runtime.count() == 2)
    }

    @Test("A missing native runtime defers without spending attempts or losing transcript and audio")
    func missingRuntimeDefers() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("missing-runtime")
        let coordinator = TranscriptionCoordinator(
            engine: Self.wordEngine(), diarizerFactory: { _ in UnavailableRuntime() },
            modelFingerprint: { _ in "test-model" })

        try await coordinator.transcribeNow(dir)

        #expect(DiarizationState.read(dir)?.status == .deferred)
        #expect(DiarizationState.read(dir)?.attempts == 0)
        #expect(PostProcessor.readTranscript(dir)?.segments.contains { $0.speaker == "them" } == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }

    @Test("Replacing upstream audio invalidates its durable ASR generation")
    func changedOriginCannotReuseASR() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("source-change")
        let engine = Self.wordEngine()
        let runtime = FaultRuntime(failures: 1)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        let provisional = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        try TestAudio.writeTone(to: dir.appendingPathComponent("system.caf"),
                                seconds: 1, frequency: 770)

        await #expect(throws: (any Error).self) {
            try await coordinator.diarizeNow(dir)
        }
        #expect(DiarizationState.read(dir)?.isOutstanding == true)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == provisional)
        #expect(engine.counts.heard.count == 2)
        #expect(await runtime.count() == 1)
    }

    @Test("A changed microphone cannot be carried into speaker-only retry")
    func changedMicrophoneRequiresWholeRetranscription() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("mic-change")
        let runtime = FaultRuntime(failures: 1)
        let coordinator = TranscriptionCoordinator(
            engine: Self.wordEngine(), diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        let good = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        try TestAudio.writeTone(to: dir.appendingPathComponent("mic.caf"),
                                seconds: 1, frequency: 330)

        await #expect(throws: (any Error).self) { try await coordinator.diarizeNow(dir) }

        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == good)
        #expect(await runtime.count() == 1)
    }

    @Test("An unavailable ASR model defers turn fallback without spending speaker attempts")
    func asrPreparationFailureDefers() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("asr-unavailable")
        let removed = OSAllocatedUnfairLock(initialState: false)
        let engine = Self.wordEngine(prepareError: {
            removed.withLock { $0 ? CocoaError(.fileReadNoSuchFile) : nil }
        })
        let runtime = FaultRuntime(failures: 1)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("asr.json"))
        removed.withLock { $0 = true }

        await #expect(throws: (any Error).self) { try await coordinator.diarizeNow(dir) }

        #expect(DiarizationState.read(dir)?.status == .deferred)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }

    @Test("Candidate text survives pending retry and is removed by whole-ASR reset")
    func candidateLifetime() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("candidate")
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6),
                             status: .pending).write(to: dir)
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        try Data("private recognized text".utf8).write(to: candidate)

        TranscriptionScratch.remove(in: dir)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
        TranscriptionScratch.remove(in: dir, includingDerivedAudio: true)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
    }

    @Test("A terminal speaker failure keeps original audio but clears stale candidate text")
    func failedDiarizationClearsCandidate() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("failed-candidate")
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6),
                             status: .failed).write(to: dir)
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        try Data("stale private candidate".utf8).write(to: candidate)

        TranscriptionScratch.remove(in: dir)

        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }

    @Test("A third inference failure clears stale candidate text without losing source audio")
    func thirdInferenceFailureClearsCandidate() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("third-failure")
        let runtime = FaultRuntime(failures: 3)
        let coordinator = TranscriptionCoordinator(
            engine: Self.wordEngine(), diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })

        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        try Data("stale candidate from earlier generation".utf8).write(to: candidate)
        await #expect(throws: (any Error).self) { try await coordinator.diarizeNow(dir) }
        #expect(DiarizationState.read(dir)?.attempts == 2)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
        await #expect(throws: (any Error).self) { try await coordinator.diarizeNow(dir) }

        #expect(DiarizationState.read(dir)?.status == .failed)
        #expect(DiarizationState.read(dir)?.attempts == 3)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        #expect(PostProcessor.readTranscript(dir) != nil)
    }

    @Test("Published commit removes candidate text even when journal cleanup was interrupted")
    func publishedCommitClearsCandidate() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("published-candidate")
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        try Data("private recognized text".utf8).write(to: candidate)
        let transcript = Transcript(engine: "parakeet", model: "fake",
            created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "ready")])
        try TranscriptVersions.commit(transcript, to: dir)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        let journal = dir.appendingPathComponent(TranscriptVersions.journalDirectory)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data().write(to: journal.appendingPathComponent("published"))

        try TranscriptVersions.recover(dir)

        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "ready")
    }

    @Test("All conflicting process flags fail before touching a folder")
    func processFlagConflicts() throws {
        for flags in [
            ["--again", "--diarize"],
            ["--again", "--skip-diarization"],
            ["--diarize", "--skip-diarization"],
        ] {
            let command = try ProcessSession.parse(flags)
            #expect(throws: ValidationError.self) { try command.run() }
        }
    }

    @Test("Threshold retry reuses durable PCM after archive and preserves archived timeline")
    func archivedThresholdRetry() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true, "diarization_threshold": 0.6,
                              "diarization_model": "community-1"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("archived")
        let engine = Self.wordEngine()
        let runtime = FaultRuntime(failures: 0)
        let modelID = OSAllocatedUnfairLock(initialState: "test-model")
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in modelID.withLock { $0 } })

        try await coordinator.transcribeNow(dir)
        let oldTranscript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let oldTimeline = try Data(contentsOf: dir.appendingPathComponent("diarization.json"))
        let priorVersionCount = TranscriptVersions.read(dir).count
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization-source-them.caf").path))
        #expect(engine.counts.heard.count == 2)
        #expect(engine.counts.heard.allSatisfy {
            $0.lastPathComponent.hasPrefix("diarization-source-")
        })
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true, "diarization_threshold": 0.8,
                              "diarization_model": "community-1"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])

        try await coordinator.diarizeNow(dir)

        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(DiarizationState.read(dir)?.request.threshold == 0.8)
        #expect(await runtime.count() == 2)
        #expect(engine.counts.heard.count == 2)
        let versions = TranscriptVersions.read(dir)
        #expect(versions.count == priorVersionCount + 1)
        let archived = try #require(versions.first {
            !$0.isCurrent && (try? Data(contentsOf: $0.dir.appendingPathComponent("transcript.json")))
                == oldTranscript
                && (try? Data(contentsOf: $0.dir.appendingPathComponent("diarization.json")))
                    == oldTimeline
        }?.dir)
        #expect(try Data(contentsOf: archived.appendingPathComponent("diarization.json"))
            == oldTimeline)
        #expect(DiarizationState.read(archived)?.status == .completed)
        modelID.withLock { $0 = "test-model-replaced" }
        try await coordinator.diarizeNow(dir)
        #expect(await runtime.count() == 3)
        #expect(engine.counts.heard.count == 2)
        #expect(TranscriptVersions.read(dir).count == priorVersionCount + 2)
    }

    @Test("Changing the speaker model archives its timeline and reuses ASR")
    func modelChangeReusesASR() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true, "diarization_model": "nemotron-3"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("model-switch")
        let engine = Self.wordEngine()
        let runtime = FaultRuntime(failures: 0)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { $0.rawValue })

        try await coordinator.transcribeNow(dir)
        let asr = try #require(DiarizationArtifacts.readASR(dir))
        let oldTimeline = try Data(contentsOf: dir.appendingPathComponent("diarization.json"))
        let priorVersionCount = TranscriptVersions.read(dir).count
        let recognized = engine.counts.heard.count
        #expect(DiarizationState.read(dir)?.request.model == .nemotron3)

        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true, "diarization_model": "ls-eend-ami"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        try await coordinator.diarizeNow(dir)

        #expect(DiarizationState.read(dir)?.request.model == .lsEendAMI)
        #expect(await runtime.count() == 2)
        #expect(engine.counts.heard.count == recognized)
        #expect(DiarizationArtifacts.readASR(dir)?.tracks.map(\.sourceFingerprint)
                == asr.tracks.map(\.sourceFingerprint))
        let versions = TranscriptVersions.read(dir)
        #expect(versions.count == priorVersionCount + 1)
        let previous = try #require(versions.first {
            !$0.isCurrent &&
                (try? Data(contentsOf: $0.dir.appendingPathComponent("diarization.json"))) == oldTimeline
        }?.dir)
        #expect(DiarizationState.read(previous)?.request.model == .nemotron3)
    }

    @Test("GigaAM turn-first route still removes the microphone echo")
    func gigaTurnRouteKeepsEchoFilter() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("giga-echo")
        let engine = FakeEngine("gigaam", answer: { _, _ in
            [TranscriptSegment(start: 0, end: 1,
                text: "one two three four five six seven eight")]
        })
        let runtime = FaultRuntime(failures: 0)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })

        try await coordinator.transcribeNow(dir)

        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(PostProcessor.readTranscript(dir)?.segments.count == 1)
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.speaker == "them")
        let echo = SessionState.value(dir, "echo_filter") as? [String: Any]
        #expect(echo?["dropped_segments"] as? Int == 1)
    }

    @Test("A proven silent remote side completes a speaking-mic session")
    func silentRemoteSideCompletes() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("silent-remote")
        try TestAudio.write(to: dir.appendingPathComponent("system.caf"), seconds: 1) {
            _, _ in 0
        }
        let engine = FakeEngine("parakeet", answer: { audio, _ in
            guard audio.lastPathComponent.contains("me") else { return [] }
            return [TranscriptSegment(start: 0, end: 1, text: "local",
                words: [TranscriptWord(start: 0, end: 1, text: "local")])]
        })
        let runtime = SilenceRuntime()

        try await TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" }).transcribeNow(dir)

        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        #expect(PostProcessor.readTranscript(dir)?.segments.map(\.speaker) == ["me"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization-source-them.caf").path))
    }

    @Test("Changed ASR options refuse speaker-only replay and keep the good generation")
    func changedASROptionsRequireWholeRetranscription() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["local_diarization": true],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("options")
        let runtime = FaultRuntime(failures: 0)
        let old = OptionsEngine(wrapped: Self.wordEngine(), optionsFingerprint: "language=ru")
        try await TranscriptionCoordinator(
            engine: old, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" }).transcribeNow(dir)
        let good = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let changed = OptionsEngine(wrapped: Self.wordEngine(), optionsFingerprint: "language=en")

        await #expect(throws: (any Error).self) {
            try await TranscriptionCoordinator(
                engine: changed, diarizerFactory: { _ in runtime },
                modelFingerprint: { _ in "test-model" }).diarizeNow(dir)
        }

        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == good)
        #expect(await runtime.count() == 1)
        #expect(changed.wrapped.counts.heard.isEmpty)
    }

    @Test("A provisional transcript remains pending and retains its audio")
    func provisionalIsOutstanding() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("pending")
        try Transcript(engine: "parakeet", model: "fake", created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Привет")]).write(to: dir)
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6),
                             status: .pending).write(to: dir)

        #expect(DiarizationState.read(dir)?.isOutstanding == true)
        #expect(SessionInventory.item(for: dir)?.isOutstanding == true)
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).map {
            $0.resolvingSymlinksInPath().path
        } == [dir.resolvingSymlinksInPath().path])
        TrackCompressor.settle(sessionDir: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }

    @Test("An unsupported persisted speaker model keeps provisional text and original audio")
    func unknownPersistedModelRetainsRecoveryData() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("unknown-model")
        try Transcript(engine: "parakeet", model: "fake", created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000,
                             text: "provisional text")]).write(to: dir)
        try SessionState.amend(dir, with: [
            DiarizationState.key: [
                "request": ["engine": "parakeet", "threshold": 0.6,
                            "model": "future-model"],
                "status": "pending",
            ],
            SessionState.Key.speakersStatus: nil,
            SessionState.Key.summaryStatus: nil,
        ])
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        try Data("provisional candidate".utf8).write(to: candidate)
        let transcript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))

        #expect(DiarizationState.read(dir) == nil,
                "An unknown model must not decode as Community-1")
        #expect(SessionInventory.item(for: dir)?.isOutstanding == true)
        #expect(PostProcessor.outstanding(dir, policy: .init(names: true, summary: true)).isEmpty)
        TranscriptionScratch.remove(in: dir)
        TrackCompressor.settle(sessionDir: dir)

        #expect(FileManager.default.fileExists(atPath: candidate.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        #expect(SessionState.value(dir, "audio_discarded") as? Bool != true)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == transcript)
        await #expect(throws: (any Error).self) {
            try await TranscriptionCoordinator(engine: Self.wordEngine()).diarizeNow(dir)
        }
        await #expect(throws: (any Error).self) {
            try await TranscriptionCoordinator(engine: Self.wordEngine()).skipDiarization(dir)
        }
        #expect(!PostProcessor.markForRetranscription(dir))
        #expect(!TranscriptVersions.isRequested(dir))
        #expect((SessionState.value(dir, DiarizationState.key) as? [String: Any])?["status"]
                as? String == "pending")
        #expect(((SessionState.value(dir, DiarizationState.key) as? [String: Any])?["request"]
                as? [String: Any])?["model"] as? String == "future-model")
    }

    @Test("An unreadable request before ASR never spends transcript retries or changes recovery files")
    func unknownBeforeTranscriptDoesNotRetireAudio() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": false,
            "transcription": ["engine": "parakeet", "local_diarization": true],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        func unknownSession(_ name: String) throws -> (URL, [String: Data]) {
            let dir = try recordings.session(name)
            try SessionState.amend(dir, with: [DiarizationState.key: [
                "request": ["engine": "parakeet", "threshold": 0.6,
                            "model": "future-model"],
                "status": "pending",
            ]])
            try Data("provisional candidate".utf8).write(
                to: dir.appendingPathComponent(DiarizationArtifacts.candidateFile))
            let files = ["meta.json", DiarizationArtifacts.candidateFile,
                         "mic.caf", "system.caf"]
            return (dir, try Dictionary(uniqueKeysWithValues: files.map {
                ($0, try Data(contentsOf: dir.appendingPathComponent($0)))
            }))
        }
        let (direct, directFiles) = try unknownSession("direct-unknown")
        let (queued, queuedFiles) = try unknownSession("queued-unknown")
        let engine = Self.wordEngine()
        let coordinator = TranscriptionCoordinator(engine: engine)

        for _ in 0..<3 {
            await #expect(throws: (any Error).self) { try await coordinator.transcribeNow(direct) }
        }
        await coordinator.drainPending(in: recordings.root)

        for (dir, files) in [(direct, directFiles), (queued, queuedFiles)] {
            for (name, bytes) in files {
                #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes)
            }
            #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
            #expect(SessionState.value(dir, SessionState.Key.transcriptionDeferred) == nil)
            #expect(SessionState.value(dir, SessionState.Key.transcriptionFailed) == nil)
            #expect(PostProcessor.readTranscript(dir) == nil)
        }
        #expect(engine.counts.heard.isEmpty)
    }

    @Test("A completed legacy Community generation can be replayed without its discarded audio")
    func completedLegacyCommunityReplayWithoutAudio() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": false,
            "transcription": ["local_diarization": true,
                              "diarization_model": "community-1"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("legacy-community")
        let engine = Self.wordEngine()
        let runtime = FaultRuntime(failures: 0)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)

        let asr = try #require(DiarizationArtifacts.readASR(dir))
        let remote = try #require(asr.tracks.first { $0.speaker == "them" })
        let legacyOptions = DiarizationArtifacts.hash("alignment-v1", "0.6")
        let legacyGeneration = DiarizationArtifacts.hash(
            remote.sourceFingerprint, "test-model", legacyOptions,
            asr.optionsFingerprint)
        var state = try #require(DiarizationState.read(dir))
        state.fingerprint = legacyGeneration
        try state.write(to: dir)
        let timelineURL = dir.appendingPathComponent(DiarizationArtifacts.timelineFile)
        var timeline = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: timelineURL)) as? [String: Any])
        timeline["generationFingerprint"] = legacyGeneration
        try JSONSerialization.data(withJSONObject: timeline).write(to: timelineURL)
        let before = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let versions = TranscriptVersions.read(dir).count
        let recognized = engine.counts.heard.count
        #expect(SessionInventory.item(for: dir)?.hasAudio == false)

        try await coordinator.diarizeNow(dir)

        #expect(await runtime.count() == 1)
        #expect(engine.counts.heard.count == recognized)
        #expect(TranscriptVersions.read(dir).count == versions)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == before)
        #expect(DiarizationState.read(dir)?.fingerprint == legacyGeneration)
    }

    @Test("Ordinary re-transcription after disabling speakers finishes as plain ASR")
    func retranscriptionHonorsDisabledDiarization() async throws {
        func config(localDiarization: Bool) throws {
            try Home.current.writeConfig([
                "offline_echo_cancellation": false, "keep_audio": true,
                "transcription": ["engine": "parakeet", "local_diarization": localDiarization,
                                  "diarization_model": "community-1"],
                "speaker_names": ["enabled": false], "summary": ["enabled": false],
            ])
        }
        try config(localDiarization: true)
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("speakers-then-plain")
        let failASR = OSAllocatedUnfairLock(initialState: false)
        let engine = FakeEngine("parakeet", answer: { audio, _ in
            if failASR.withLock({ $0 }) { throw URLError(.cannotLoadFromNetwork) }
            let text = audio.lastPathComponent.contains("them") ? "remote" : "local"
            return [TranscriptSegment(start: 0, end: 1, text: text,
                words: [TranscriptWord(start: 0, end: 1, text: text)])]
        })
        let runtime = FaultRuntime(failures: 0)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.status == .completed)
        let oldTranscript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let oldTimeline = try Data(contentsOf: dir.appendingPathComponent("diarization.json"))
        let oldRuntimeCalls = await runtime.count()

        try config(localDiarization: false)
        #expect(PostProcessor.markForRetranscription(dir))
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == oldTranscript)
        #expect(try Data(contentsOf: dir.appendingPathComponent("diarization.json")) == oldTimeline)
        failASR.withLock { $0 = true }
        await #expect(throws: (any Error).self) { try await coordinator.transcribeNow(dir) }
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == oldTranscript)
        #expect(try Data(contentsOf: dir.appendingPathComponent("diarization.json")) == oldTimeline)
        #expect(TranscriptVersions.isRequested(dir))

        failASR.withLock { $0 = false }
        try await coordinator.transcribeNow(dir)

        #expect(PostProcessor.readTranscript(dir)?.engine == "parakeet")
        #expect(!TranscriptVersions.isRequested(dir))
        #expect(DiarizationState.persisted(in: dir).isFinal)
        #expect(await runtime.count() == oldRuntimeCalls)
        let work = PostProcessor.outstanding(dir, policy: .init(names: true, summary: true))
        #expect(work.names && work.summary)
        let versions = TranscriptVersions.read(dir)
        let archived = try #require(versions.first {
            !$0.isCurrent &&
                (try? Data(contentsOf: $0.dir.appendingPathComponent("diarization.json")))
                    == oldTimeline
        }?.dir)
        #expect(DiarizationState.read(archived)?.status == .completed)
    }

    @Test("GigaAM ordinary re-transcription with speakers off skips turn-first inference")
    func gigaRetranscriptionHonorsDisabledDiarization() async throws {
        func config(localDiarization: Bool) throws {
            try Home.current.writeConfig([
                "offline_echo_cancellation": false, "keep_audio": true,
                "transcription": ["engine": "gigaam", "local_diarization": localDiarization,
                                  "diarization_model": "community-1"],
                "speaker_names": ["enabled": false], "summary": ["enabled": false],
            ])
        }
        try config(localDiarization: true)
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("giga-speakers-then-plain")
        let engine = FakeEngine("gigaam", answer: { _, _ in
            [TranscriptSegment(start: 0, end: 1, text: "spoken words")]
        })
        let runtime = FaultRuntime(failures: 0)
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.status == .completed)
        let calls = await runtime.count()

        try config(localDiarization: false)
        #expect(PostProcessor.markForRetranscription(dir))
        try await coordinator.transcribeNow(dir)

        #expect(await runtime.count() == calls)
        #expect(DiarizationState.persisted(in: dir).isFinal)
        #expect(PostProcessor.readTranscript(dir)?.engine == "gigaam")
        let work = PostProcessor.outstanding(dir, policy: .init(names: true, summary: true))
        #expect(work.names && work.summary)
    }

    @Test("GigaAM failed inference during replacement records one attempt and archives old speakers")
    func gigaReplacementFailureKeepsAttemptAndOldGeneration() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "keep_audio": true,
            "transcription": ["engine": "gigaam", "local_diarization": true,
                              "diarization_model": "community-1"],
            "speaker_names": ["enabled": false], "summary": ["enabled": false],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("giga-replacement-failure")
        let engine = FakeEngine("gigaam", answer: { _, _ in
            [TranscriptSegment(start: 0, end: 1, text: "spoken words")]
        })
        let runtime = FailSecondRuntime()
        let coordinator = TranscriptionCoordinator(
            engine: engine, diarizerFactory: { _ in runtime },
            modelFingerprint: { _ in "test-model" })
        try await coordinator.transcribeNow(dir)
        #expect(DiarizationState.read(dir)?.status == .completed)
        #expect(await runtime.count() == 1)
        let oldTimeline = try Data(contentsOf: dir.appendingPathComponent("diarization.json"))

        #expect(PostProcessor.markForRetranscription(dir))
        try await coordinator.transcribeNow(dir)

        #expect(await runtime.count() == 2,
                "A failed turn-first run must not immediately launch a second inference")
        #expect(DiarizationState.read(dir)?.status == .pending)
        #expect(DiarizationState.read(dir)?.attempts == 1)
        #expect(PostProcessor.readTranscript(dir)?.engine == "gigaam")
        let archived = try #require(TranscriptVersions.read(dir).first {
            !$0.isCurrent &&
                (try? Data(contentsOf: $0.dir.appendingPathComponent("diarization.json")))
                    == oldTimeline
        }?.dir)
        #expect(DiarizationState.read(archived)?.status == .completed)
    }

    @Test("Only inference errors spend the three-attempt budget")
    func inferenceBudget() {
        var state = DiarizationState(request: .init(engine: "whisper", threshold: 0.6),
                                     status: .pending)
        state.deferForEnvironment("model unavailable")
        #expect(state.attempts == 0)
        for n in 1...3 {
            state.beginInference(fingerprint: "same")
            state.failInference("bad inference")
            #expect(state.attempts == n)
            #expect(state.status == (n == 3 ? .failed : .pending))
        }
        state.beginInference(fingerprint: "changed")
        #expect(state.attempts == 1)
    }

    @Test("Older state without rejected-turn count still decodes")
    func stateWithoutQualityCount() throws {
        let state = DiarizationState(request: .init(engine: "parakeet", threshold: 0.6),
                                     status: .completed)
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "rejectedTurnCount")
        let decoded = try JSONDecoder().decode(DiarizationState.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.status == .completed)
        #expect(decoded.rejectedTurnCount == nil)
    }

    @Test("Legacy transcripts have no requested diarization")
    func legacyIsFinished() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("legacy")
        try Transcript(engine: "parakeet", model: "fake", created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "Привет")]).write(to: dir)
        #expect(DiarizationState.read(dir) == nil)
        #expect(!TranscriptionCoordinator.pendingSessions(in: recordings.root).contains(dir))
    }

    @Test("An interrupted multi-file publication restores the previous generation")
    func interruptedPublicationRecovers() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("recovery")
        let old = Transcript(engine: "parakeet", model: "one", created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them A", start_ms: 0, end_ms: 1000, text: "Один")])
        try old.write(to: dir)
        let oldJSON = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let oldMarkdown = try Data(contentsOf: dir.appendingPathComponent("transcript.md"))
        let candidate = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        let oldCandidate = Data("retry candidate".utf8)
        try oldCandidate.write(to: candidate)
        let journal = dir.appendingPathComponent(TranscriptVersions.journalDirectory)
        try FileManager.default.createDirectory(at: journal.appendingPathComponent("previous"),
                                                withIntermediateDirectories: true)
        try oldJSON.write(to: journal.appendingPathComponent("previous/transcript.json"))
        try oldMarkdown.write(to: journal.appendingPathComponent("previous/transcript.md"))
        try oldCandidate.write(to: journal.appendingPathComponent(
            "previous/\(DiarizationArtifacts.candidateFile)"))
        try JSONSerialization.data(withJSONObject: [
            "files": ["transcript.json", "transcript.md", "diarization.json",
                      DiarizationArtifacts.candidateFile],
            "existing": ["transcript.json", "transcript.md",
                         DiarizationArtifacts.candidateFile],
        ]).write(to: journal.appendingPathComponent("manifest.json"))
        try Data("new incomplete generation".utf8).write(to: dir.appendingPathComponent("transcript.json"))
        try Data("new private timeline".utf8).write(to: dir.appendingPathComponent("diarization.json"))
        try FileManager.default.removeItem(at: candidate)

        try TranscriptVersions.recover(dir)

        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.json")) == oldJSON)
        #expect(try Data(contentsOf: dir.appendingPathComponent("transcript.md")) == oldMarkdown)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization.json").path))
        #expect(try Data(contentsOf: candidate) == oldCandidate)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("An ASR sidecar from another transcript generation is ignored")
    func asrGenerationBound() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("generation")
        let old = Transcript(engine: "parakeet", model: "fake", created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "old")])
        try old.write(to: dir)
        let sidecar = DiarizationArtifacts.ASR(
            transcriptSHA256: try DiarizationArtifacts.transcriptHash(old),
            engine: "parakeet", model: "fake", optionsFingerprint: "opts", tracks: [])
        try DiarizationArtifacts.encode(sidecar)
            .write(to: dir.appendingPathComponent(DiarizationArtifacts.asrFile))
        #expect(DiarizationArtifacts.readASR(dir) != nil)

        let new = Transcript(engine: "parakeet", model: "fake", created_at: "2026-10-09T00:00:01Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "new")])
        try new.write(to: dir)
        #expect(DiarizationArtifacts.readASR(dir) == nil)
    }

    @Test("Skipping before ASR exists keeps the only source audio")
    func skipWithoutTranscriptKeepsSource() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("no-asr")
        try DiarizationState(request: .init(engine: "parakeet", threshold: 0.6),
                             status: .pending).write(to: dir)

        await #expect(throws: (any Error).self) {
            try await TranscriptionCoordinator().skipDiarization(dir)
        }

        #expect(DiarizationState.read(dir)?.status == .pending)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        #expect(SessionState.value(dir, "audio_discarded") == nil)
    }

    @Test("Publishing a requested transcript consumes its request marker")
    func commitClearsRequestMarker() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("again")
        try Data("parakeet".utf8).write(to: dir.appendingPathComponent(TranscriptVersions.requestFile))
        let transcript = Transcript(engine: "parakeet", model: "fake",
            created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "ready")])

        try TranscriptVersions.commit(transcript, to: dir)

        #expect(!TranscriptVersions.isRequested(dir))
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "ready")
    }

    @Test("Whole-transcript replacement removes sidecars from the current generation")
    func replacementClearsOldSidecars() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("new-asr")
        let old = Transcript(engine: "parakeet", model: "fake",
            created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them A", start_ms: 0, end_ms: 1000, text: "old")])
        try old.write(to: dir)
        try Data("old asr".utf8).write(to: dir.appendingPathComponent("asr.json"))
        try Data("old timeline".utf8).write(to: dir.appendingPathComponent("diarization.json"))
        let new = Transcript(engine: "whisper", model: "new",
            created_at: "2026-10-09T00:00:01Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 1000, text: "new")])

        try TranscriptVersions.commit(new, to: dir, sidecars: [
            DiarizationArtifacts.asrFile: nil,
            DiarizationArtifacts.timelineFile: nil,
        ])

        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("asr.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization.json").path))
        #expect(PostProcessor.readTranscript(dir)?.segments.first?.text == "new")
    }

    @Test("Identical transcript JSON keeps distinct speaker generations and names")
    func identicalTextHasDistinctSpeakerVersions() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("same-text")
        let transcript = Transcript(engine: "parakeet", model: "fake",
            created_at: "2026-10-09T00:00:00Z",
            segments: [.init(speaker: "them A", start_ms: 0, end_ms: 1000, text: "same")])
        try transcript.write(to: dir)
        let json = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let hash = DiarizationArtifacts.sha256(json)
        func writeTimeline(_ fingerprint: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "transcriptSHA256": hash,
                "generationFingerprint": fingerprint, "result": [:],
            ]).write(to: dir.appendingPathComponent("diarization.json"))
        }
        func writeName(_ name: String) throws {
            try SpeakerNames(created_at: "2026-10-09T00:00:00Z", speakers: [
                "them A": .init(name: name, source: .manual),
            ]).write(to: dir)
        }
        try writeTimeline(DiarizationArtifacts.hash("first"))
        try writeName("First")
        let first = try #require(try TranscriptVersions.archiveCurrent(dir))
        try writeTimeline(DiarizationArtifacts.hash("second"))
        try writeName("Second")
        let second = try #require(try TranscriptVersions.archiveCurrent(dir))

        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("transcript.json")) == json)
        #expect(try Data(contentsOf: second.appendingPathComponent("transcript.json")) == json)
        #expect(SpeakerNames.read(from: first)?.name(for: "them A") == "First")
        #expect(SpeakerNames.read(from: second)?.name(for: "them A") == "Second")
        #expect(TranscriptVersions.read(dir).count == 2)
        let secondReplay = try #require(try TranscriptVersions.archiveCurrent(dir))
        #expect(secondReplay == second)
        #expect(TranscriptVersions.read(dir).count == 2)

        // A timeline not bound to these JSON bytes keeps the legacy raw hash.
        let unbound = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "transcriptSHA256": "wrong",
            "generationFingerprint": DiarizationArtifacts.hash("third"), "result": [:],
        ])
        try unbound.write(to: dir.appendingPathComponent("diarization.json"))
        let legacy = try #require(try TranscriptVersions.archiveCurrent(dir))
        #expect(legacy.lastPathComponent == hash)
        let legacyReplay = try #require(try TranscriptVersions.archiveCurrent(dir))
        #expect(legacyReplay == legacy)
    }

    @Test("Recovery rejects an untrusted journal path before touching outside files")
    func recoveryRejectsJournalTraversal() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("journal-traversal")
        let outside = recordings.root.appendingPathComponent("outside.txt")
        try Data("safe".utf8).write(to: outside)
        let journal = dir.appendingPathComponent(TranscriptVersions.journalDirectory)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "files": ["../outside.txt"], "existing": ["../outside.txt"],
        ]).write(to: journal.appendingPathComponent("manifest.json"))

        #expect(throws: (any Error).self) { try TranscriptVersions.recover(dir) }
        #expect(try Data(contentsOf: outside) == Data("safe".utf8))
    }
}
