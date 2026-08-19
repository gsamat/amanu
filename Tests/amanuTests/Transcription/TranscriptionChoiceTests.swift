import Foundation
import Testing

@testable import amanu

/// The setup window's two switches against the config's one `engine` string.
///
/// This is the translation the whole redesign rests on: a person answers "may
/// audio leave this Mac" and "keep the local model ready", and those two
/// answers have to come back out of the config file as the same two answers
/// next time the window opens.
struct TranscriptionChoiceTests {
    private static func read(
        _ engine: String,
        cloud: String = "assemblyai",
        enabled: Bool = true,
        localModels: Bool = true
    ) -> TranscriptionChoice {
        TranscriptionChoice.read(
            engine: engine, cloudProvider: cloud, enabled: enabled, localModels: localModels)
    }

    private static func written(_ choice: TranscriptionChoice) -> [String: String] {
        var out: [String: String] = [:]
        for update in choice.updates {
            let key = update.path.joined(separator: ".")
            out[key] = update.value.map { "\($0)" } ?? "nil"
        }
        return out
    }

    @Test("Both switches on is auto, and auto is both switches on")
    func autoIsBoth() {
        let choice = Self.read("auto")
        #expect(choice.cloud)
        #expect(choice.local)

        let written = Self.written(choice)
        #expect(written["transcription.engine"] == "nil")
        #expect(written["transcription.enabled"] == "nil")
    }

    /// The footer asks whether the local model is missing, and it has to ask
    /// the switch. Asked of the engine string — which is absent whenever both
    /// switches are on — the window said nothing at all in the commonest
    /// setting there is, and went back to promising that everything amanu
    /// needs is here while the model it would transcribe with was not.
    @Test("Both switches on still wants the local model on disk")
    func bothSwitchesStillWantTheModel() {
        #expect(Self.read("auto").needsLocalModel(downloaded: false))
        #expect(!Self.read("auto").needsLocalModel(downloaded: true))
        #expect(Self.read("parakeet").needsLocalModel(downloaded: false))
        // Cloud only, or nothing at all, is not asking for it.
        #expect(!Self.read("assemblyai").needsLocalModel(downloaded: false))
        #expect(!Self.read("auto", enabled: false).needsLocalModel(downloaded: false))
        // And a Mac that cannot run it is not missing it.
        #expect(!Self.read("auto", localModels: false).needsLocalModel(downloaded: false))
    }

    @Test("One switch each way names an engine outright")
    func oneSided() {
        #expect(Self.read("parakeet") == TranscriptionChoice(
            cloud: false, local: true, provider: "assemblyai"))
        #expect(Self.read("assemblyai") == TranscriptionChoice(
            cloud: true, local: false, provider: "assemblyai"))
        #expect(Self.read("openai") == TranscriptionChoice(
            cloud: true, local: false, provider: "openai"))

        let cloudOnly = Self.written(
            TranscriptionChoice(cloud: true, local: false, provider: "openai"))
        let localOnly = Self.written(
            TranscriptionChoice(cloud: false, local: true, provider: "openai"))
        #expect(cloudOnly["transcription.engine"] == "openai")
        #expect(localOnly["transcription.engine"] == "parakeet")
    }

    /// The engine names the provider, so a config that says `openai` is read
    /// as openai whatever the separate `cloud` setting happens to hold.
    @Test("A named cloud engine outranks the cloud setting")
    func namedEngineWins() {
        #expect(Self.read("openai", cloud: "assemblyai").provider == "openai")
        #expect(Self.read("auto", cloud: "openai").provider == "openai")
    }

    /// Turning both off is "record only" — and it must not also throw away
    /// which engines were chosen, because turning one back on is one click.
    @Test("Neither switch means transcription off, and nothing else is touched")
    func neither() {
        let written = Self.written(
            TranscriptionChoice(cloud: false, local: false, provider: "openai"))
        #expect(written["transcription.enabled"] == "false")
        #expect(written["transcription.engine"] == nil)
        #expect(written["transcription.cloud"] == nil)

        let read = Self.read("auto", enabled: false)
        #expect(!read.cloud)
        #expect(!read.local)
        // Still remembered, so the cards show the right one while it is off.
        #expect(read.provider == "assemblyai")
    }

    /// The default provider is removed rather than written out: a config file
    /// holding only what was actually chosen is one a person can read.
    @Test("Only a non-default provider is written to the config")
    func defaultProviderIsNotWritten() {
        let byDefault = Self.written(
            TranscriptionChoice(cloud: true, local: true, provider: "assemblyai"))
        let chosen = Self.written(
            TranscriptionChoice(cloud: true, local: true, provider: "openai"))
        #expect(byDefault["transcription.cloud"] == "nil")
        #expect(chosen["transcription.cloud"] == "openai")
    }

    /// The Intel half of the universal binary: there is no local model, so
    /// the local switch cannot be on however the config reads.
    @Test("Without local models the local switch is always off")
    func intel() {
        #expect(!Self.read("auto", localModels: false).local)
        #expect(!Self.read("parakeet", localModels: false).local)
        // And auto still means the cloud there — the engine that can run.
        #expect(Self.read("auto", localModels: false).cloud)
    }

    /// An engine name from a future version, or a typo, is auto — the same
    /// thing the coordinator falls back to, so the window never shows a state
    /// the transcription queue would not act on.
    @Test("An unknown engine reads as auto")
    func unknownIsAuto() {
        let choice = Self.read("whisper")
        #expect(choice.cloud)
        #expect(choice.local)
    }
}
