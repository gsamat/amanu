import CoreAudio
import Foundation
import Testing

@testable import amanu

/// Which microphone the mic track should be on. Asking Core Audio needs a real
/// call in progress; the rule that reads its answer does not, and the rule is
/// where the meeting gets recorded off the wrong microphone.
struct MicRouteTests {
    private func device(_ id: AudioObjectID, _ name: String) -> MicRoute.Device {
        MicRoute.Device(id: id, name: name)
    }

    @Test func nothingIsOnTheMicrophoneSoTheDefaultStands() {
        let fallback = device(1, "MacBook Pro Microphone")
        #expect(MicRoute.choose(callAppInputs: [], default: fallback) == fallback)
    }

    /// The case the whole thing exists for: Zoom is on a microphone the system
    /// was never told about, and the track has to follow Zoom rather than the
    /// default nobody is talking into.
    @Test func theCallAppsMicrophoneBeatsTheDefault() {
        let usb = device(7, "Shure MV7")
        let builtIn = device(1, "MacBook Pro Microphone")
        #expect(MicRoute.choose(callAppInputs: [usb], default: builtIn) == usb)
    }

    @Test func twoCallAppsAndTheDefaultIsOneOfThemSettlesIt() {
        let builtIn = device(1, "MacBook Pro Microphone")
        let usb = device(7, "Shure MV7")
        #expect(MicRoute.choose(callAppInputs: [usb, builtIn], default: builtIn) == builtIn)
    }

    /// Neither is the default — somebody is talking into both, and a
    /// microphone with a person on it beats one nobody selected.
    @Test func twoCallAppsAndNeitherIsTheDefaultTakesTheFirst() {
        let usb = device(7, "Shure MV7")
        let airpods = device(9, "AirPods Pro")
        let builtIn = device(1, "MacBook Pro Microphone")
        #expect(MicRoute.choose(callAppInputs: [usb, airpods], default: builtIn) == usb)
    }

    /// No default either — a Mac with no input device at all. The engine is
    /// left to whatever it can find rather than being pointed at nothing.
    @Test func withoutAnyAnswerTheEngineIsLeftAlone() {
        #expect(MicRoute.choose(callAppInputs: [], default: nil) == nil)
    }
}
