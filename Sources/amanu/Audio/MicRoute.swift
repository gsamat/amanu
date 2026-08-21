import CoreAudio
import Foundation

/// Which microphone the "me" track should be recording.
///
/// The answer amanu used to give was "whichever one was the default when the
/// engine started", which is wrong twice over. It is wrong when the default
/// changes mid-meeting, because `AVAudioEngine` stays on the device it was
/// built around and says nothing (measured 20 August 2026: the default input
/// was switched under a running recording and capture carried on with the old
/// microphone). And it is wrong when the call app is not on the default at
/// all — pick another microphone in Zoom's settings and Zoom moves, while the
/// system default, and therefore amanu, does not.
///
/// So the question is asked the way the system-audio tap already asks its own:
/// follow the call app. `kAudioProcessPropertyDevices` says which device a
/// process is running input on, and that device — not the default — is the one
/// the user is talking into. The default is the fallback for everything else:
/// no call app, no answer from Core Audio, a meeting held in an app amanu does
/// not know about.
enum MicRoute {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String?
    }

    /// The microphone capture should be on, given the call app families this
    /// session is following. Nil when the system will not name one, which
    /// leaves the engine to its own default — the behaviour of every version
    /// before this one.
    static func preferred(callApps families: [String]) -> Device? {
        let inputs = AudioProcesses.matching(families: families)
            .filter(\.runningInput)
            .flatMap { AudioProcesses.inputDevices(of: $0) }
            .filter { AudioDevices.hasInput($0) }
            .map { Device(id: $0, name: AudioDevices.name(of: $0)) }
        let fallback = AudioDevices.defaultInput()
            .map { Device(id: $0, name: AudioDevices.name(of: $0)) }
        return choose(callAppInputs: inputs, default: fallback)
    }

    /// The choice itself, over what has already been asked of Core Audio — the
    /// same rule without the questions, so it can be tested.
    ///
    /// A call app on the default device is the ordinary case and settles
    /// itself. When several are open on different devices, the default wins if
    /// it is among them, because that is the one the user last chose in a
    /// place that asked; otherwise the first, because any microphone somebody
    /// is talking into beats a default nobody selected.
    static func choose(callAppInputs: [Device], default fallback: Device?) -> Device? {
        guard !callAppInputs.isEmpty else { return fallback }
        if let fallback, callAppInputs.contains(fallback) { return fallback }
        return callAppInputs[0]
    }
}
