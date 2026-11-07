import AVFoundation
import Foundation
import Testing

@testable import amanu

struct CompatibleTranscriptionTests {
    private typealias Engine = CompatibleTranscriptionEngine
    private static let mlx = #"{"text":"Привет мир.","segments":[{"text":"Привет","start":0.1,"end":0.3,"speaker":0},{"text":"мир.","start":0.35,"end":0.6,"speaker":0}],"generation_tokens":12}"#

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-compatible-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func compatibleProfilesResolveWithoutGuessingRemoteHosts() throws {
        let local = try Engine.resolve(baseURL: " http://127.0.0.1:8000/v1/ ", protocol: .automatic, model: "test")
        #expect(local.profile == .mlxAudio)
        #expect(local.local)
        #expect(local.endpoint.absoluteString == "http://127.0.0.1:8000/v1/audio/transcriptions")
        let di = try Engine.resolve(baseURL: "https://api.deepinfra.com/v1", protocol: .automatic, model: "nvidia/model")
        #expect(di.profile == .deepInfra)
        #expect(di.endpoint.absoluteString == "https://api.deepinfra.com/v1/inference/nvidia/model")
        let router = try Engine.resolve(baseURL: "https://openrouter.ai/api/v1", protocol: .automatic, model: "nvidia/model")
        #expect(router.profile == .openRouter)
        #expect(router.endpoint.path == "/api/v1/audio/transcriptions")
        let proxy = try Engine.resolve(baseURL: "https://speech.example/team/v1", protocol: .mlxAudio, model: "model")
        #expect(proxy.endpoint.path == "/team/v1/audio/transcriptions")
        #expect(!proxy.local)
        #expect(throws: Engine.Failure.self) {
            try Engine.resolve(baseURL: "https://speech.example/v1", protocol: .automatic, model: "model")
        }
        for invalid in ["http://speech.example/v1", "https://user:secret@api.deepinfra.com/v1",
                        "https://api.deepinfra.com/v1?token=secret", "https://api.deepinfra.com/v1#fragment",
                        "https://api.deepinfra.com/v1/openai", "https://api.deepinfra.com/v1/inference/model"] {
            #expect(throws: Engine.Failure.self) {
                try Engine.resolve(baseURL: invalid, protocol: .deepInfra, model: "nvidia/model")
            }
        }
        for model in ["../model", "nvidia//model", "nvidia/model?key=x", "nvidia/model#fragment"] {
            #expect(throws: Engine.Failure.self) {
                try Engine.resolve(baseURL: "https://api.deepinfra.com/v1", protocol: .deepInfra, model: model)
            }
        }
    }

    @Test func compatibleAuthAndLocationAreIndependentOfAudioShape() throws {
        let engine = try Engine(baseURL: "http://localhost:8000/v1", model: "test")
        #expect(engine.input == .mixed)
        #expect(engine.supportsDiarization)
        #expect(!engine.runsRemotely)
        let remote = try Engine(baseURL: "https://speech.example/v1", model: "test", apiProtocol: .mlxAudio)
        #expect(remote.runsRemotely)
        #expect(throws: Engine.Failure.noAPIKey) {
            try Engine(baseURL: "https://openrouter.ai/api/v1", model: "test", apiKey: " \n")
        }
    }

    @Test func compatibleFieldsMatchEachProviderRatherThanSendingAUnion() throws {
        let mlx = Dictionary(uniqueKeysWithValues: Engine.requestFields(profile: .mlxAudio, model: "mlx-model", expected: ["ru", "en"]))
        #expect(mlx["model"] == "mlx-model")
        #expect(mlx["response_format"] == "verbose_json")
        #expect(mlx["word_timestamps"] == "true")
        #expect(mlx["max_tokens"] == "16384")
        #expect(mlx["stream"] == "false")
        #expect(mlx["prompt"]?.contains("<spk:7>") == true)
        #expect(mlx["diarize"] == nil && mlx["task"] == nil && mlx["language"] == nil)
        let di = Dictionary(uniqueKeysWithValues: Engine.requestFields(profile: .deepInfra, model: "di-model", expected: ["en"]))
        #expect(di == ["chunk_level": "word", "diarize": "true", "task": "transcribe", "temperature": "0", "language": "en"])
        let router = Dictionary(uniqueKeysWithValues: Engine.requestFields(profile: .openRouter, model: "or-model", expected: []))
        #expect(router["model"] == "or-model")
        #expect(router["timestamp_granularities[]"] == "word")
        #expect(router["diarize"] == "true")
        #expect(router["word_timestamps"] == nil && router["prompt"] == nil && router["max_tokens"] == nil)

        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("part.wav")
        try Data([1, 2, 3]).write(to: wav)
        let body = dir.appendingPathComponent("body")
        try CloudHTTP.writeMultipart(fields: [("diarize", "true")], file: wav, boundary: "test", to: body, fileField: "audio")
        let wire = String(decoding: try Data(contentsOf: body), as: UTF8.self)
        #expect(wire.contains("name=\"audio\"; filename=\"part.wav\""))
        #expect(wire.contains("Content-Type: audio/wav\r\n"))
        #expect(!wire.contains("name=\"file\""))
    }

    @Test func compatibleParsesSpeakerAliasesAndIgnoresAudioEvents() throws {
        let json = #"{"text":"Один [смех] два три.","words":[{"word":"Один","start":0.1,"end":0.2,"speaker":3,"speaker_label":"Анна"},{"word":"[смех]","start":0.21,"end":0.3,"type":"audio_event"},{"word":"два","start":0.31,"end":0.4,"speaker_label":"Анна","type":"word"},{"word":"три.","start":0.41,"end":0.6,"speaker":"4"}]}"#
        let words = try Engine.words(from: Data(json.utf8), profile: .openRouter, duration: 1)
        #expect(words.map(\.speaker) == ["3", "3", "4"])
        let segments = Engine.segments(from: words, offset: 2_400, speakerPrefix: "p2-")
        #expect(segments.map(\.text) == ["Один два", "три."])
        #expect(segments.map(\.speaker) == ["p2-A", "p2-B"])
        #expect(segments[0].start == 2_400.1)
        #expect(segments[1].end == 2_400.6)
        let di = #"{"words":[{"word":"Слово","start":0.2,"end":0.4,"speaker":"SPEAKER_01"}],"inference_status":{"status":"succeeded"}}"#
        #expect(try Engine.words(from: Data(di.utf8), profile: .deepInfra, duration: 1).count == 1)
        #expect(try Engine.words(from: Data(Self.mlx.utf8), profile: .mlxAudio, duration: 1).count == 2)
        #expect(try Engine.words(from: Data(json.replacingOccurrences(of: "Один [смех] два три.", with: "Один два три.").utf8), profile: .openRouter, duration: 1).count == 3)
    }

    @Test func compatibleRejectsMissingDiarizationInvalidTimesAndTruncation() throws {
        let invalid = [
            #"{"text":"only plain text"}"#,
            #"{"segments":[{"text":"word","start":0.1,"end":0.2}]}"#,
            #"{"segments":[{"text":"word","start":0.1,"end":0.1,"speaker":0}]}"#,
            #"{"segments":[{"text":"word","start":-0.1,"end":0.2,"speaker":0}]}"#,
            #"{"segments":[{"text":"word","start":1.05,"end":1.1,"speaker":0}]}"#,
            #"{"segments":[{"text":"word","start":0.1,"end":4,"speaker":0}]}"#,
        ]
        for json in invalid {
            #expect(throws: Engine.Failure.malformed) {
                try Engine.words(from: Data(json.utf8), profile: .mlxAudio, duration: 1)
            }
        }
        for incomplete in [#"{"text":"lost words","segments":[]}"#,
                           #"{"text":"<spk:0> one two","segments":[{"text":"one","start":0.1,"end":0.2,"speaker":0}],"generation_tokens":2}"#] {
            #expect(throws: Engine.Failure.incomplete) {
                try Engine.words(from: Data(incomplete.utf8), profile: .mlxAudio, duration: 1)
            }
        }
        let reordered = #"{"text":"<spk:0> one <spk:1> two","segments":[{"text":"two","start":0.1,"end":0.2,"speaker":1},{"text":"one","start":0.2,"end":0.3,"speaker":0}]}"#
        #expect(try Engine.words(from: Data(reordered.utf8), profile: .mlxAudio, duration: 1).map(\.text) == ["two", "one"])
        let limit = #"{"segments":[],"generation_tokens":16384}"#
        #expect(throws: Engine.Failure.incomplete) {
            try Engine.words(from: Data(limit.utf8), profile: .mlxAudio, duration: 1)
        }
        let failed = #"{"words":[],"inference_status":{"status":"failed"}}"#
        #expect(throws: Engine.Failure.incomplete) {
            try Engine.words(from: Data(failed.utf8), profile: .deepInfra, duration: 1)
        }
        let conflict = #"{"words":[{"word":"one","start":0.1,"end":0.2,"speaker":0,"speaker_label":"same"},{"word":"two","start":0.2,"end":0.3,"speaker":1,"speaker_label":"same"}]}"#
        #expect(throws: Engine.Failure.malformed) {
            try Engine.words(from: Data(conflict.utf8), profile: .openRouter, duration: 1)
        }
        // Alignment can contain submillisecond spans. Preserve its actual
        // seconds; downstream rounds outward when saving milliseconds.
        let tiny = #"{"segments":[{"text":"в","start":0.1,"end":0.10001,"speaker":0}]}"#
        #expect(try Engine.words(from: Data(tiny.utf8), profile: .mlxAudio, duration: 1).count == 1)
    }

    @Test func compatibleTurnAssemblyPreservesAllWordsAndBreaksAtPauses() {
        let words = [
            Engine.Word(start: 0, end: 0.2, text: "Первая", speaker: "0"),
            Engine.Word(start: 0.25, end: 0.4, text: "фраза.", speaker: "0"),
            Engine.Word(start: 0.5, end: 0.7, text: "Вторая", speaker: "0"),
            Engine.Word(start: 2, end: 2.2, text: "после паузы", speaker: "0"),
            Engine.Word(start: 2.3, end: 2.5, text: "Ответ", speaker: "1"),
        ]
        let turns = Engine.segments(from: words)
        #expect(turns.map(\.text) == ["Первая фраза.", "Вторая", "после паузы", "Ответ"])
        #expect(turns.map(\.speaker) == ["A", "A", "A", "B"])
    }

    @Test func compatiblePreparationMixesRightChannelAndCutsWithoutDroppingFrames() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("stereo.caf")
        try TestAudio.write(to: source, seconds: 2.3, sampleRate: 48_000, channels: 2) { channel, frame in
            channel == 0 ? 0 : 0.4 * Float(sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        let prepared = try await CompatibleAudio.prepare(source, in: dir, aac: false, chunkDuration: 1, maximumUploadBytes: 24_000_000)
        #expect(prepared.pieces.count == 3)
        #expect(prepared.pieces.map(\.firstFrame) == [0, 16_000, 32_000])
        #expect(prepared.pieces.reduce(0) { $0 + $1.frames } == 36_800)
        #expect(prepared.pieces.last?.duration == 0.3)
        for piece in prepared.pieces {
            let file = try AVAudioFile(forReading: piece.url)
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.length == piece.frames)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) }
            #expect(energy > 1)
        }
    }

    @Test func compatibleAACSizeGuardRecutsTheRemainderInsteadOfLosingIt() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.caf")
        try TestAudio.writeTone(to: source, seconds: 6, frequency: 440)
        let unbounded = dir.appendingPathComponent("unbounded")
        let bounded = dir.appendingPathComponent("bounded")
        try FileManager.default.createDirectory(at: unbounded, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bounded, withIntermediateDirectories: true)
        let full = try await CompatibleAudio.prepare(source, in: unbounded, aac: true, chunkDuration: 6, maximumUploadBytes: 24_000_000)
        // M4A reserves a container header, so an arbitrary tiny cap may not
        // fit even one frame. Force a split relative to the actual encoding.
        let fullBytes = try #require(full.pieces[0].url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let limit = fullBytes - 1_000
        let prepared = try await CompatibleAudio.prepare(source, in: bounded, aac: true, chunkDuration: 6, maximumUploadBytes: limit)
        #expect(prepared.pieces.count > 1)
        #expect(prepared.pieces.reduce(0) { $0 + $1.frames } == 96_000)
        var next: Int64 = 0
        for piece in prepared.pieces {
            #expect(piece.firstFrame == next)
            next += piece.frames
            #expect(try piece.url.resourceValues(forKeys: [.fileSizeKey]).fileSize! < limit)
            let file = try AVAudioFile(forReading: piece.url)
            #expect(file.fileFormat.channelCount == 1)
            #expect(file.fileFormat.sampleRate == 16_000)
        }
    }

    @Test func compatibleCacheSurvivesLaterPieceFailureAndLivesInSessionDirectory() async throws {
        let session = try folder()
        defer { try? FileManager.default.removeItem(at: session) }
        let temporaryAudio = session.appendingPathComponent(".transcription-aec-test")
        try FileManager.default.createDirectory(at: temporaryAudio, withIntermediateDirectories: true)
        let audio = temporaryAudio.appendingPathComponent("mixed.caf")
        try TestAudio.writeTone(to: audio, seconds: 2, frequency: 440)
        let stub = StubHTTP { _, count in count == 2 ? .status(503) : .json(200, Self.mlx) }
        let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session, retry: .once, chunkDuration: 1)
        await #expect(throws: Engine.Failure.unavailable(503)) {
            try await engine.transcribe(audio, cacheDirectory: session)
        }
        #expect(ProviderCache.files(in: session).count == 1)
        #expect(ProviderCache.files(in: temporaryAudio).isEmpty)
        let retry = try await engine.transcribe(audio, cacheDirectory: session)
        #expect(stub.requests.count == 3)
        #expect(retry.map(\.speaker) == ["p1-A", "p2-A"])
        #expect(retry[1].start == 1.1)
        #expect(ProviderCache.files(in: session).count == 2)
        _ = try await engine.transcribe(audio, cacheDirectory: session)
        #expect(stub.requests.count == 3)
        #expect(TranscriptionScratch.items(in: session).contains { $0.lastPathComponent.hasPrefix("transcript.compatible.") })
    }

    /// A recording, a config with no echo cancellation (so the mix lives in the
    /// session folder) and no installed review UI, for the coordinator tests.
    private func withRecording(
        attempts: Int? = nil, _ body: (URL) async throws -> Void
    ) async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        var state: [String: Any] = [:]
        if let attempts { state[SessionState.Key.transcriptionAttempts] = attempts }
        let dir = try recordings.session("2026-11-06-a", seconds: 3, state: state)
        let home = Home.withModels([])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["offline_echo_cancellation": false, "keep_audio": true,
                              "transcription": ["engine": "compatible"]])
        try await Home.$scoped.withValue(home) {
            try await SpeakerReview.$usesInstalledHandler.withValue(false) { try await body(dir) }
        }
    }

    @Test("A manual retry after a later piece fails pays only for that piece, also once attempts run out",
          arguments: [false, true])
    func compatibleManualRetryReusesCompletedPieces(exhausted: Bool) async throws {
        try await withRecording(attempts: exhausted ? TranscriptionFailurePolicy.maxAttempts - 1 : nil) { dir in
            let stub = StubHTTP { _, count in count == 2 ? .status(503) : .json(200, Self.mlx) }
            let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session,
                                    retry: .once, chunkDuration: 2)
            let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
            await #expect(throws: Engine.Failure.unavailable(503)) { try await coordinator.transcribeNow(dir) }
            #expect(stub.requests.count == 2)
            #expect(PostProcessor.readTranscript(dir) == nil)
            #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir) == exhausted)
            #expect(TranscriptionScratch.resumableCaches(in: dir).count == 1)
            // Retirement compresses audio only when nothing paid for depends on it.
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptionInputs.mixedFile).path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptionInputs.mixedIdentityFile).path))

            // The window's Re-transcribe, its inline retry and `amanu process --again`.
            #expect(PostProcessor.markForRetranscription(dir))
            #expect(TranscriptionScratch.resumableCaches(in: dir).count == 1)
            try await coordinator.transcribeNow(dir)
            #expect(stub.requests.count == 3, "Only the failed piece is sent again")
            let transcript = try #require(PostProcessor.readTranscript(dir))
            #expect(transcript.segments.count == 2)
            #expect(transcript.segments[1].start_ms >= 2_000)
            #expect(TranscriptionScratch.resumableCaches(in: dir).isEmpty,
                    "A published transcript leaves no cached piece behind")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptionInputs.mixedIdentityFile).path))
        }
    }

    @Test("A retry remixes changed source audio or timing instead of reusing a stale transcript",
          arguments: ["audio", "offset"])
    func compatibleRetryRechecksMixSources(_ change: String) async throws {
        try await withRecording { dir in
            let stub = StubHTTP { _, count in count == 2 ? .status(503) : .json(200, Self.mlx) }
            let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session,
                                    retry: .once, chunkDuration: 2)
            let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
            await #expect(throws: Engine.Failure.unavailable(503)) { try await coordinator.transcribeNow(dir) }
            #expect(stub.requests.count == 2)
            #expect(TranscriptionScratch.resumableCaches(in: dir).count == 1)

            if change == "audio" {
                let source = dir.appendingPathComponent("mic.caf")
                let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
                let modified = try #require(attrs[.modificationDate] as? Date)
                try FileManager.default.removeItem(at: source)
                try TestAudio.writeTone(to: source, seconds: 3, frequency: 880)
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
                let updated = try FileManager.default.attributesOfItem(atPath: source.path)
                #expect((updated[.size] as? NSNumber) == (attrs[.size] as? NSNumber),
                        "The fingerprint must notice changed bytes even with unchanged size and mtime")
            } else {
                try SessionState.amend(dir, with: ["start_offset_ms": ["mic": 0, "system": 500]])
            }

            #expect(PostProcessor.markForRetranscription(dir))
            try await coordinator.transcribeNow(dir)
            #expect(stub.requests.count == 4, "Both chunks must be requested for the changed mix")
            #expect(PostProcessor.readTranscript(dir) != nil)
            #expect(TranscriptionScratch.resumableCaches(in: dir).isEmpty)
        }
    }

    @Test("A retry with a different model after a failed piece pays again and never reuses the old piece")
    func compatibleRetryWithChangedSettingsDoesNotReuse() async throws {
        try await withRecording { dir in
            let stub = StubHTTP { _, count in count == 2 ? .status(503) : .json(200, Self.mlx) }
            let first = try Engine(baseURL: "http://localhost/v1", model: "one", session: stub.session,
                                   retry: .once, chunkDuration: 2)
            await #expect(throws: Engine.Failure.unavailable(503)) {
                try await TranscriptionCoordinator(engine: first, onStop: { nil }).transcribeNow(dir)
            }
            #expect(PostProcessor.markForRetranscription(dir))
            let second = try Engine(baseURL: "http://localhost/v1", model: "two", session: stub.session,
                                    retry: .once, chunkDuration: 2)
            try await TranscriptionCoordinator(engine: second, onStop: { nil }).transcribeNow(dir)
            #expect(stub.requests.count == 4, "Both pieces are asked of the new model")
            #expect(PostProcessor.readTranscript(dir)?.model == "two")
            #expect(TranscriptionScratch.resumableCaches(in: dir).isEmpty,
                    "The other model's piece goes with the published transcript")
        }
    }

    @Test("Only compatible pieces are kept for a retry; other providers' answers are still cleared")
    func retryKeepsOnlyResumablePieces() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let piece = dir.appendingPathComponent("transcript.compatible.0011223344556677.json")
        let other = dir.appendingPathComponent("transcript.assemblyai.multichannel.json")
        let mix = dir.appendingPathComponent(TranscriptionInputs.mixedFile)
        let identity = dir.appendingPathComponent(TranscriptionInputs.mixedIdentityFile)
        let multichannel = dir.appendingPathComponent(TranscriptionInputs.multichannelFile)
        for file in [piece, other, mix, identity, multichannel] { try Data("x".utf8).write(to: file) }
        let kept = TranscriptionScratch.items(in: dir, includingDerivedAudio: true, keepingResumable: true)
        #expect(Set(kept.map(\.lastPathComponent)) == [other.lastPathComponent, multichannel.lastPathComponent])
        #expect(TranscriptionScratch.items(in: dir, includingDerivedAudio: true).count == 5,
                "Without a resumable run nothing changes")
        try FileManager.default.removeItem(at: piece)
        #expect(TranscriptionScratch.items(in: dir, includingDerivedAudio: true, keepingResumable: true)
            .contains(mix), "The mix is kept only for pieces cut from it")
        #expect(TranscriptionScratch.items(in: dir, includingDerivedAudio: true, keepingResumable: true)
            .contains(identity), "An identity without a resumable run is removed")
    }

    @Test func compatibleCacheIncludesEndpointModelAndAudioContent() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let stub = StubHTTP { _, _ in .json(200, Self.mlx) }
        let first = try Engine(baseURL: "http://localhost/v1", model: "one", session: stub.session)
        _ = try await first.transcribe(audio)
        _ = try await first.transcribe(audio)
        #expect(stub.requests.count == 1)
        let model = try Engine(baseURL: "http://localhost/v1", model: "two", session: stub.session)
        _ = try await model.transcribe(audio)
        let host = try Engine(baseURL: "http://127.0.0.1/v1", model: "two", session: stub.session)
        _ = try await host.transcribe(audio)
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 880)
        _ = try await host.transcribe(audio)
        #expect(stub.requests.count == 4)
    }

    @Test(arguments: [401, 402, 403, 413, 400])
    func compatibleHTTPRefusalsPreserveAudioAndDoNotRetry(status: Int) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let stub = StubHTTP { _, _ in .status(status) }
        let engine = try Engine(baseURL: "https://api.deepinfra.com/v1", model: "nvidia/model", apiKey: "secret", session: stub.session)
        do {
            _ = try await engine.transcribe(audio)
            Issue.record("HTTP refusal unexpectedly became a transcript")
        } catch let failure as Engine.Failure {
            #expect(failure.isEnvironmental)
            #expect(!failure.isPermanent)
            if status == 402 { #expect(failure == .insufficientCredits) }
            if [401, 403].contains(status) { #expect(failure == .unauthorized(status)) }
        }
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].path == "/v1/inference/nvidia/model")
        #expect(stub.requests[0].header("Authorization") == "Bearer secret")
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(ProviderCache.files(in: dir).isEmpty)
    }

    @Test("OpenRouter identifies unsupported diarization without exposing server content")
    func compatibleOpenRouterDiarizationRefusal() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let unsupported = #"{"error":{"message":"The selected model does not support diarize. Remove the field or choose a model whose provider supports it.","code":400},"private":"do-not-report"}"#
        let unrelated = #"{"error":{"message":"do-not-report","code":400}}"#
        for (profile, body, expected) in [
            (CompatibleTranscriptionProtocol.openRouter, unsupported, Engine.Failure.diarizationUnsupported),
            (.openRouter, unrelated, .rejected(400)),
            (.deepInfra, unsupported, .rejected(400)),
        ] {
            let stub = StubHTTP { _, _ in .json(400, body) }
            let base = profile == .openRouter ? "https://openrouter.ai/api/v1" : "https://api.deepinfra.com/v1"
            let engine = try Engine(baseURL: base, model: "nvidia/model", apiKey: "secret",
                                    apiProtocol: profile, session: stub.session, retry: .once)
            do {
                _ = try await engine.transcribe(audio)
                Issue.record("A rejected request must not become a transcript")
            } catch let failure as Engine.Failure {
                #expect(failure == expected)
                #expect(failure.isEnvironmental && !failure.isPermanent)
                #expect(!failure.description.contains("do-not-report"))
                #expect(!failure.description.contains("secret"))
            }
            #expect(stub.requests.count == 1)
            #expect(FileManager.default.fileExists(atPath: audio.path))
            #expect(ProviderCache.files(in: dir).isEmpty)
        }
    }

    @Test func compatibleRetriesServerFailuresAndRejectsMalformedSuccessWithoutCaching() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let stub = StubHTTP { _, count in count == 1 ? .status(429, headers: ["Retry-After": "0"]) : .json(200, #"{"text":"No timestamps"}"#) }
        let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session, sleep: { _ in })
        await #expect(throws: Engine.Failure.malformed) { try await engine.transcribe(audio) }
        #expect(stub.requests.count == 2)
        #expect(stub.requests[0].header("Authorization") == nil)
        #expect(ProviderCache.files(in: dir).isEmpty)
    }

    @Test(arguments: [CompatibleTranscriptionProtocol.deepInfra, .openRouter])
    func compatibleCloudProfilesUseTheCorrectRouteAndDecodeTimedWords(profile: CompatibleTranscriptionProtocol) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let json = #"{"text":"Привет.","words":[{"word":"Привет.","start":0.1,"end":0.5,"speaker":"speaker_0"}]}"#
        let stub = StubHTTP { _, _ in .json(200, json) }
        let base = profile == .deepInfra ? "https://api.deepinfra.com/v1" : "https://openrouter.ai/api/v1"
        let engine = try Engine(baseURL: base, model: "nvidia/model", apiKey: "token", session: stub.session)
        let turns = try await engine.transcribe(audio)
        #expect(turns.map(\.text) == ["Привет."])
        #expect(turns.map(\.speaker) == ["A"])
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].path == (profile == .deepInfra ? "/v1/inference/nvidia/model" : "/api/v1/audio/transcriptions"))
        #expect(stub.requests[0].header("Authorization") == "Bearer token")
    }

    @Test func compatibleDroppedUploadsAreNotAutomaticallySubmittedAgain() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let stub = StubHTTP { _, _ in .failure(.networkConnectionLost) }
        let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session)
        await #expect(throws: URLError.self) { try await engine.transcribe(audio) }
        #expect(stub.requests.count == 1)
        #expect(ProviderCache.files(in: dir).isEmpty)
    }

    @Test func compatibleCancellationDoesNotRetryOrCacheAnUnfinishedUpload() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.caf")
        try TestAudio.writeTone(to: audio, seconds: 1, frequency: 440)
        let stub = StubHTTP { _, _ in .hang }
        let engine = try Engine(baseURL: "http://localhost/v1", model: "test", session: stub.session)
        let task = Task { try await engine.transcribe(audio) }
        for _ in 0..<200 where stub.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!stub.requests.isEmpty)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stub.requests.count == 1)
        #expect(ProviderCache.files(in: dir).isEmpty)
    }

    /// Opt-in public-fixture test against a user-started server. Never starts
    /// a runtime, downloads a model, or permits a remote/paid endpoint.
    @Test("Compatible client transcribes the public Russian ABAB fixture",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_COMPATIBLE_TEST_URL"] != nil
              && ProcessInfo.processInfo.environment["AMANU_COMPATIBLE_TEST_MODEL"] != nil
              && ProcessInfo.processInfo.environment["AMANU_COMPATIBLE_TEST_AUDIO"] != nil
              && ProcessInfo.processInfo.environment["AMANU_COMPATIBLE_TEST_REFERENCE"] != nil))
    func compatibleLocalPublicFixtureSmoke() async throws {
        let env = ProcessInfo.processInfo.environment
        let engine = try Engine(
            baseURL: try #require(env["AMANU_COMPATIBLE_TEST_URL"]),
            model: try #require(env["AMANU_COMPATIBLE_TEST_MODEL"]), apiProtocol: .mlxAudio)
        try #require(engine.isLocalEndpoint, "The opt-in smoke test only allows loopback endpoints")
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = URL(fileURLWithPath: try #require(env["AMANU_COMPATIBLE_TEST_AUDIO"]))
        let referenceURL = URL(fileURLWithPath: try #require(env["AMANU_COMPATIBLE_TEST_REFERENCE"]))
        struct Reference: Decodable { let expected_normalized_text: String; let duration_seconds: Double }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
        let audio = dir.appendingPathComponent("public.wav")
        try FileManager.default.copyItem(at: source, to: audio)
        try await engine.prepare()
        let turns = try await engine.transcribe(audio)
        await engine.release()
        #expect(!turns.isEmpty)
        #expect(Set(turns.compactMap(\.speaker)).count == 2)
        #expect(turns.allSatisfy { $0.start >= 0 && $0.end > $0.start && $0.end <= reference.duration_seconds })
        let text = turns.map(\.text).joined(separator: " ").lowercased().replacingOccurrences(of: "ё", with: "е")
        let normalized = text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // The known CTC alignment can move a word across a turn boundary.
        // This qualifies transport/coverage, not word timing accuracy or WER.
        let actual = normalized.split(separator: " ").reduce(into: [String: Int]()) {
            $0[String($1), default: 0] += 1
        }
        let expected = reference.expected_normalized_text.split(separator: " ").reduce(into: [String: Int]()) {
            $0[String($1), default: 0] += 1
        }
        #expect(actual == expected)
    }

    /// Validate a locally saved native response without embedding or printing
    /// recordings/transcripts in tests. Also useful for long-audio alignment
    /// regressions that cannot be represented by a tiny synthetic response.
    @Test("Saved native response has complete timed speech",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_COMPATIBLE_RESPONSE_JSON"] != nil))
    func compatibleSavedResponseValidation() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["AMANU_COMPATIBLE_RESPONSE_JSON"]))
        let duration = Double(env["AMANU_COMPATIBLE_RESPONSE_DURATION"] ?? "2400") ?? 2400
        let words = try Engine.words(from: Data(contentsOf: url), profile: .mlxAudio, duration: duration)
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.end > $0.start && $0.start >= 0 && $0.end <= duration })
    }
}
