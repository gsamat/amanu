import Foundation
import Testing

@testable import amanu

/// What the configured engine adds up to, decided before any network call.
/// The interesting half is the Intel one: amanu ships a universal binary, and
/// the x86_64 slice has no local models at all — so the questions are what it
/// falls back to, and what it does when there is nothing to fall back to.
struct EngineSelectionTests {
    private static func choice(
        _ configured: String, key: Bool, localModels: Bool
    ) -> TranscriptionCoordinator.EngineChoice {
        TranscriptionCoordinator.resolveEngine(
            configured: configured, hasKey: key, localModels: localModels)
    }

    @Test("On Apple Silicon auto prefers the cloud only when there is a key")
    func autoOnAppleSilicon() {
        #expect(Self.choice("auto", key: true, localModels: true) == .cloudOrLocal)
        #expect(Self.choice("auto", key: false, localModels: true) == .local)
    }

    /// Catches an Intel Mac being handed a local engine that throws
    /// `unsupportedPlatform` deep inside Core ML — the same session failing
    /// three times and retiring, instead of transcribing through the cloud.
    @Test("Without local models auto is the cloud engine, with no local rescue")
    func autoWithoutLocalModels() {
        #expect(Self.choice("auto", key: true, localModels: false) == .cloud)
    }

    /// An Intel Mac with no key can't transcribe at all, and the queue has to
    /// say so rather than pick an engine that cannot run.
    @Test("Without local models and without a key there is no engine")
    func nothingAvailable() {
        #expect(Self.choice("auto", key: false, localModels: false) == .unavailable)
        #expect(Self.choice("parakeet", key: false, localModels: false) == .unavailable)
    }

    /// The one place a stated preference is overridden: parakeet cannot run
    /// here, and a transcript through the other engine beats no transcript.
    @Test("A configured parakeet falls back to the cloud when it cannot run")
    func parakeetFallsBack() {
        #expect(Self.choice("parakeet", key: true, localModels: false) == .cloud)
        #expect(Self.choice("parakeet", key: true, localModels: true) == .local)
    }

    /// assemblyai is not overridden in either direction: it is chosen for
    /// diarization, which the local engine does not do, so a missing key is a
    /// failure to report rather than a reason to transcribe differently.
    @Test("A configured assemblyai is never swapped for the local engine")
    func assemblyAIStays() {
        #expect(Self.choice("assemblyai", key: false, localModels: true) == .cloud)
        #expect(Self.choice("assemblyai", key: true, localModels: false) == .cloud)
    }

    @Test("An unrecognised engine name is treated as auto")
    func unknownIsAuto() {
        #expect(Self.choice("whisper", key: true, localModels: true) == .cloudOrLocal)
        #expect(Self.choice("", key: false, localModels: true) == .local)
    }
}
