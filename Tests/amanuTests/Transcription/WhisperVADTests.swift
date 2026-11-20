import Foundation
import Testing
import whisper

@testable import amanu

struct WhisperVADTests {
    @Test("Whisper VAD is opt-in and automatic language policy remains the default", .freshHome(config: "{}"))
    func defaultsPreserveExistingBehavior() throws {
        #expect(!Config.whisperVAD())
        #expect(Config.whisperLanguage() == nil)
        let engine = WhisperEngine(expectedLanguages: ["ru", "en"])
        #expect(!engine.usesVAD)
        #expect(engine.language == nil)
        let entry = try #require(SettingsSchema.everyEntry.first {
            $0.path == ["transcription", "whisper", "vad"]
        })
        #expect(entry.defaultValue as? Bool == false)
    }

    @Test("A monolingual Whisper override is explicit rather than changing meeting languages",
          .freshHome(config: #"{"transcription":{"language":"ru","whisper":{"vad":true,"language":"ru"}}}"#))
    func explicitRussianOverride() {
        let engine = WhisperEngine()
        #expect(engine.usesVAD)
        #expect(engine.language == "ru")
        #expect(MeetingLanguages.expected(primary: Config.transcriptionLanguage()) == ["ru", "en"])
    }

    @Test("Disabled VAD never downloads or prepares its model")
    func disabledDoesNotDownload() async throws {
        let runtime = VADRecordingRuntime()
        let engine = WhisperEngine(
            modelStore: try fixtureStore(installed: true), runtime: runtime,
            vadModelStore: try fixtureStore(installed: false), usesVAD: false)
        try await engine.prepare()
        #expect(await runtime.prepared)
        #expect(await runtime.vadModel == nil)
    }

    @Test("Enabled VAD passes only a verified model to the runtime")
    func enabledPreparesVerifiedModel() async throws {
        let runtime = VADRecordingRuntime()
        let vad = try fixtureStore(installed: true)
        let engine = WhisperEngine(
            modelStore: try fixtureStore(installed: true), runtime: runtime,
            vadModelStore: vad, usesVAD: true)
        try await engine.prepare()
        #expect(await runtime.vadModel == vad.modelURL)
    }

    @Test("The optional VAD model is downloaded once and then verified locally")
    func enabledDownloadsOnlyOnce() async throws {
        let runtime = VADRecordingRuntime()
        let vad = WhisperModelStore(directory: try temporaryDirectory(), manifest: manifest()) {
            _, partial, _ in
            try Data("model".utf8).write(to: partial)
            await runtime.noteDownload()
        }
        let engine = WhisperEngine(
            modelStore: try fixtureStore(installed: true), runtime: runtime,
            vadModelStore: vad, usesVAD: true)
        try await engine.prepare()
        try await engine.prepare()
        #expect(await runtime.downloads == 1)
        #expect(await runtime.vadModel == vad.modelURL)
    }

    @Test("A corrupt VAD model fails preparation instead of silently disabling VAD")
    func corruptModelDoesNotReachRuntime() async throws {
        let runtime = VADRecordingRuntime()
        let directory = try temporaryDirectory()
        let bad = WhisperModelStore(directory: directory, manifest: manifest(sha: String(repeating: "0", count: 64))) {
            _, partial, _ in try Data("model".utf8).write(to: partial)
        }
        let engine = WhisperEngine(
            modelStore: try fixtureStore(installed: true), runtime: runtime,
            vadModelStore: bad, usesVAD: true)
        await #expect(throws: WhisperModelStore.Error.invalidSHA256) {
            try await engine.prepare()
        }
        #expect(await runtime.prepared == false)
    }

    @Test("The pinned VAD artifact has an immutable revision, size and SHA-256")
    func pinnedModelManifest() {
        let manifest = WhisperModelStore.vadManifest
        #expect(manifest.revision.count == 40)
        #expect(manifest.downloadURL.path.contains("/\(manifest.revision)/"))
        #expect(manifest.expectedBytes == 885_098)
        #expect(manifest.sha256 == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
    }

    @Test("VAD config reaches native parameters without changing decoder defaults")
    func nativeParameters() {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let temperature = params.temperature
        let strategy = params.strategy
        "fixture-vad.bin".withCString { path in
            WhisperVADParameters.apply(to: &params, modelPath: path)
            #expect(params.vad)
            #expect(String(cString: params.vad_model_path) == "fixture-vad.bin")
            #expect(params.vad_params.threshold == 0.5)
            #expect(params.vad_params.min_speech_duration_ms == 250)
            #expect(params.vad_params.min_silence_duration_ms == 100)
            #expect(params.vad_params.speech_pad_ms == 30)
            #expect(params.vad_params.max_speech_duration_s == Float.greatestFiniteMagnitude)
            #expect(params.vad_params.samples_overlap == 0.1)
            #expect(params.temperature == temperature)
            #expect(params.strategy == strategy)
        }
        WhisperVADParameters.apply(to: &params, modelPath: nil)
        #expect(!params.vad)
        #expect(params.vad_model_path == nil)
    }

    private func fixtureStore(installed: Bool) throws -> WhisperModelStore {
        let directory = try temporaryDirectory()
        let manifest = manifest()
        if installed {
            try Data("model".utf8).write(to: directory.appendingPathComponent(manifest.fileName))
        }
        return WhisperModelStore(directory: directory, manifest: manifest) { _, _, _ in
            Issue.record("this model must not download")
            throw VADUnexpectedDownload()
        }
    }

    private func manifest(sha: String = "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4") -> WhisperModelStore.Manifest {
        .init(id: "fixture", fileName: "model.bin", revision: "fixture",
              downloadURL: URL(string: "https://example.test/model.bin")!,
              expectedBytes: 5, sha256: sha)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-vad-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct VADUnexpectedDownload: Error {}

private actor VADRecordingRuntime: WhisperRuntime {
    private(set) var prepared = false
    private(set) var vadModel: URL?
    private(set) var downloads = 0

    func noteDownload() { downloads += 1 }

    func prepare(model: URL, vadModel: URL?) async throws {
        prepared = true
        self.vadModel = vadModel
    }

    func transcribe(samples: [Float], language: String?,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [WhisperRuntimeSegment] {
        []
    }

    func release() async {}
}
