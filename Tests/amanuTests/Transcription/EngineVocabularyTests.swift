import Foundation
import Testing

@testable import amanu

/// The names engines call themselves, against the closed vocabulary analytics
/// is allowed to send. A name outside it is not an error anywhere — it is
/// quietly reported as `custom` — which is how a year of local Whisper
/// transcripts would have been counted as nobody's engine at all.
struct EngineVocabularyTests {
    /// Every engine the program can build, with a key for each cloud one so
    /// that its initializer has nothing to refuse.
    private static func everyEngine() throws -> [any TranscriptionEngine] {
        try withFreshHome { home in
            try FileManager.default.createDirectory(
                at: home.keysDirectory, withIntermediateDirectories: true)
            for service in ["assemblyai", "openai", "elevenlabs", "fishaudio"] {
                try Data("test-key".utf8).write(
                    to: home.keysDirectory.appendingPathComponent(service))
            }
            return [
                ParakeetEngine(), WhisperEngine(), GigaAMEngine(),
                try AssemblyAIEngine(), try OpenAITranscriptionEngine(), try ElevenLabsEngine(),
                try FishAudioEngine(),
            ]
        }
    }

    @Test("Every engine's own name is a word analytics may send")
    func engineNamesAreInTheVocabulary() throws {
        for engine in try Self.everyEngine() {
            let sanitized = AnalyticsCatalogue.sanitized(["engine": engine.name])
            #expect(sanitized["engine"] as? String == engine.name, "\(engine.name)")
        }
    }

    @Test("Every engine the config can name is a word analytics may send")
    func configuredNamesAreInTheVocabulary() {
        for name in Config.localEngines.union(Config.cloudEngines).union(["auto"]) {
            for key in ["engine", "from_engine", "to_engine", "transcription_engine"] {
                #expect(AnalyticsCatalogue.sanitized([key: name])[key] as? String == name,
                        "\(key): \(name)")
            }
        }
    }

    @Test("An engine's name is the one the config file uses for it")
    func engineNamesMatchTheConfig() throws {
        let names = Set(try Self.everyEngine().map(\.name))
        #expect(names == Config.localEngines.union(Config.cloudEngines))
    }

    @Test("Every engine's default model is reported by name, not as custom")
    func defaultModelsAreKnown() throws {
        for engine in try Self.everyEngine() {
            let model = AnalyticsCatalogue.transcriptionModel(
                engine: engine.name, provenance: engine.model)
            #expect(model != "custom" && model != "unknown", "\(engine.name): \(engine.model)")
        }
    }
}
