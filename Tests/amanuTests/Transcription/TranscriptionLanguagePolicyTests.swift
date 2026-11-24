import Foundation
import Testing

@testable import amanu

struct TranscriptionLanguagePolicyTests {
    @Test("New configurations detect the language without creating settings", .freshHome(config: "{}"))
    func newConfigurationIsAutomatic() {
        #expect(Config.transcriptionLanguagePolicy() == .automatic)
        #expect(Config.transcriptionLanguagePolicy().expectedLanguages.isEmpty)
        #expect(Config.raw().isEmpty)
    }

    @Test(
        "Explicit auto ignores the saved language and the old Whisper pin",
        .freshHome(config: #"{"transcription":{"language_mode":"auto","language":"en","whisper":{"language":"ru"}}}"#))
    func autoHasNoHiddenPin() {
        #expect(Config.transcriptionLanguagePolicy(for: "whisper") == .automatic)
        #expect(WhisperEngine().language == nil)
        #expect(Config.transcriptionLanguagePolicy(for: "openai").expectedLanguages.isEmpty)
    }

    @Test(
        "Fixed Russian means Russian alone, not Russian plus English",
        .freshHome(config: #"{"transcription":{"language_mode":"fixed","language":" RU "}}"#))
    func fixedRussianIsShared() {
        for engine in ["whisper", "openai", "assemblyai", "elevenlabs", "gigaam"] {
            let policy = Config.transcriptionLanguagePolicy(for: engine)
            #expect(policy == .fixed("ru"))
            #expect(policy.expectedLanguages == ["ru"])
        }
        #expect(WhisperEngine().language == "ru")
    }

    @Test(
        "An old primary language keeps the former mixed-language policy",
        .freshHome(config: #"{"transcription":{"language":"ru"}}"#))
    func oldRussianIsNotSilentlyPinned() {
        let policy = Config.transcriptionLanguagePolicy()
        #expect(policy == .legacy(primary: "ru"))
        #expect(policy.expectedLanguages == ["ru", "en"])
        #expect(WhisperEngine().language == nil)
    }

    @Test(
        "Old English configurations keep their existing English pin",
        .freshHome(config: #"{"transcription":{"language":"en"}}"#))
    func oldEnglishIsNotSilentlyUnpinned() {
        let expected = Config.transcriptionLanguagePolicy(for: "openai").expectedLanguages
        #expect(expected == ["en"])
        #expect(OpenAITranscriptionEngine.languageField(for: expected) == "en")
        #expect(WhisperEngine().language == "en")
    }

    @Test(
        "The retired Whisper override is read only for legacy Whisper configurations",
        .freshHome(config: #"{"transcription":{"engine":"whisper","language":"en","whisper":{"language":"ru"}}}"#))
    func oldWhisperPinIsCompatible() {
        #expect(Config.transcriptionLanguagePolicy() == .fixed("ru"))
        #expect(Config.transcriptionLanguagePolicy(for: "whisper") == .fixed("ru"))
        #expect(Config.transcriptionLanguagePolicy(for: "openai") == .legacy(primary: "en"))
        #expect(SettingsSchema.strayKeys(in: Config.raw()).isEmpty)
    }

    @Test(
        "The common fixed mode wins over a stale Whisper override",
        .freshHome(config: #"{"transcription":{"language_mode":"fixed","language":"en","whisper":{"language":"ru"}}}"#))
    func commonPolicyWins() {
        #expect(WhisperEngine().language == "en")
    }

    @Test("Saving auto is explicit and removes the retired override", .freshHome(config: "{}"))
    func savingAutoDoesNotRestoreLegacyBehavior() {
        #expect(Config.update(path: ["transcription", "whisper", "language"], value: "en"))
        #expect(Config.setTranscriptionLanguage(mode: "fixed", language: "ru"))
        #expect(Config.setTranscriptionLanguage(mode: "auto", language: "ru"))
        #expect(Config.transcriptionLanguageMode() == "auto")
        #expect(Config.transcriptionLanguage() == "ru")
        #expect(Config.transcriptionLanguagePolicy(for: "whisper") == .automatic)
        #expect((Config.raw()["transcription"] as? [String: Any])?["whisper"] == nil)
    }

    @Test(
        "Opening a legacy configuration does not rewrite it",
        .freshHome(config: #"{"transcription":{"language":"ru"}}"#))
    func compatibilityIsReadOnly() throws {
        let before = try Data(contentsOf: Config.path)
        _ = Config.transcriptionLanguagePolicy()
        #expect(try Data(contentsOf: Config.path) == before)
    }

    @Test(
        "Fixed mode requires a language instead of falling back to detection",
        .freshHome(config: #"{"transcription":{"language_mode":"fixed"}}"#))
    func missingFixedLanguageIsAnError() {
        let policy = Config.transcriptionLanguagePolicy()
        #expect(throws: TranscriptionLanguagePolicy.ConfigurationError.self) {
            try policy.validate(engine: "whisper", model: "large-v3-turbo-q5_0")
        }
        #expect(!Config.problems().isEmpty)
    }

    @Test("Bad modes and missing or malformed fixed codes remain visible errors")
    func invalidPoliciesDoNotFallBack() {
        let configurations: [[String: Any]] = [
            ["language_mode": "unknown", "language": "ru"],
            ["language_mode": "FIXED", "language": "ru"],
            ["language_mode": false, "language": "ru"],
            ["language_mode": "fixed", "language": ""],
            ["language_mode": "fixed", "language": "ru-RU"],
            ["language_mode": "fixed", "language": "zz"],
        ]
        for transcription in configurations {
            let json = ["transcription": transcription]
            let policy = Config.transcriptionLanguagePolicy(in: json)
            #expect(throws: TranscriptionLanguagePolicy.ConfigurationError.self) {
                try policy.validate(engine: "whisper", model: "large-v3-turbo-q5_0")
            }
            #expect(!Config.unusableValues(in: json).isEmpty)
        }
    }

    @Test("Unsupported fixed modes fail rather than being treated as hints")
    func unsupportedEnginesAreHonest() throws {
        #expect(throws: TranscriptionLanguagePolicy.ConfigurationError.self) {
            try TranscriptionLanguagePolicy.fixed("ru").validate(engine: "parakeet", model: "v3")
        }
        #expect(throws: TranscriptionLanguagePolicy.ConfigurationError.self) {
            try TranscriptionLanguagePolicy.fixed("en").validate(engine: "gigaam", model: "gigaam")
        }
        try TranscriptionLanguagePolicy.fixed("ru").validate(engine: "gigaam", model: "gigaam")
        try TranscriptionLanguagePolicy.fixed("en").validate(engine: "parakeet", model: "v2")
    }

    @Test("A fixed language is sent to AssemblyAI with detection disabled")
    func assemblyAIHasOneLanguageMode() {
        let body = AssemblyAIEngine.requestBody(
            audioURL: "https://example.test/audio", expectedLanguages: ["ru"], speechModel: nil,
            fixedLanguage: "ru")
        #expect(body["language_code"] as? String == "ru")
        #expect(body["language_detection"] as? Bool == false)
        #expect(body["language_detection_options"] == nil)
    }

    @Test("ElevenLabs sends a language only for an explicit fixed mode")
    func elevenLabsLanguageIsExplicit() {
        let fixed = Dictionary(uniqueKeysWithValues: ElevenLabsEngine.requestFields(language: "ru"))
        let automatic = Dictionary(uniqueKeysWithValues: ElevenLabsEngine.requestFields())
        #expect(fixed["language_code"] == "ru")
        #expect(automatic["language_code"] == nil)
    }

    @Test("Explicit auto is not erased by the generic settings resolver")
    func schemaDoesNotClearAuto() throws {
        let entry = try #require(
            SettingsSchema.everyEntry.first {
                $0.path == ["transcription", "language_mode"]
            })
        if case .set(let value) = SettingsSchema.resolve(.choice("auto"), for: entry) {
            #expect(value as? String == "auto")
        } else {
            Issue.record("Clearing auto would reactivate the old mixed-language policy")
        }
    }

    @Test(
        "Changing the actual language request changes provider cache keys",
        .freshHome(config: #"{"transcription":{"language":"en"}}"#))
    func languageModeInvalidatesProviderCaches() async throws {
        let audio = URL(fileURLWithPath: "/tmp/amanu-language-policy/audio.m4a")
        let oldAssembly = try AssemblyAIEngine(apiKey: "fixture")
        let oldEleven = try ElevenLabsEngine(apiKey: "fixture")
        let oldOpenAI = try OpenAITranscriptionEngine(apiKey: "fixture")
        let assemblyKey = await oldAssembly.cacheURL(for: audio, multichannel: true)
        let elevenKey = await oldEleven.cacheURL(for: audio, channel: 0)
        let openAIKey = await oldOpenAI.cacheURL(in: audio.deletingLastPathComponent(), audio: audio, piece: 0, of: 1)
        Config.setTranscriptionLanguage(mode: "fixed", language: "en")
        let fixedAssembly = try AssemblyAIEngine(apiKey: "fixture")
        let fixedEleven = try ElevenLabsEngine(apiKey: "fixture")
        let fixedOpenAI = try OpenAITranscriptionEngine(apiKey: "fixture")
        #expect(await fixedAssembly.cacheURL(for: audio, multichannel: true) != assemblyKey)
        #expect(await fixedEleven.cacheURL(for: audio, channel: 0) != elevenKey)
        // Both old English and explicit fixed English send the same OpenAI
        // language parameter, so that compatible cache should remain usable.
        #expect(
            await fixedOpenAI.cacheURL(in: audio.deletingLastPathComponent(), audio: audio, piece: 0, of: 1)
                == openAIKey)
        Config.setTranscriptionLanguage(mode: "auto", language: "en")
        let autoOpenAI = try OpenAITranscriptionEngine(apiKey: "fixture")
        #expect(
            await autoOpenAI.cacheURL(in: audio.deletingLastPathComponent(), audio: audio, piece: 0, of: 1) != openAIKey
        )
    }

    @Test(
        "A new language decision replaces the queue's prepared engine",
        .freshHome(config: #"{"transcription":{"engine":"whisper","language_mode":"auto"}}"#))
    func languageModeReleasesPreparedEngines() async throws {
        let resolver = EngineResolver(environment: .fake())
        let session = URL(fileURLWithPath: "/tmp/amanu-language-policy/session")
        let first = try #require(try await resolver.engine(for: session) as? FakeEngine)
        Config.setTranscriptionLanguage(mode: "fixed", language: "ru")
        let second = try #require(try await resolver.engine(for: session) as? FakeEngine)
        #expect(first !== second)
        #expect(first.counts.released == 1)
        #expect(second.counts.prepared == 1)
        await resolver.release()
    }

    @Test(
        "Changing an ignored saved code in Auto does not reload the model",
        .freshHome(config: #"{"transcription":{"engine":"whisper","language_mode":"auto","language":"ru"}}"#))
    func ignoredCodeDoesNotReload() async throws {
        let resolver = EngineResolver(environment: .fake())
        let session = URL(fileURLWithPath: "/tmp/amanu-language-policy/session")
        let first = try #require(try await resolver.engine(for: session) as? FakeEngine)
        Config.setTranscriptionLanguage(mode: "auto", language: "en")
        let second = try #require(try await resolver.engine(for: session) as? FakeEngine)
        #expect(first === second)
        #expect(first.counts.released == 0)
        await resolver.release()
    }
}
