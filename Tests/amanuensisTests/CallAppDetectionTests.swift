import Foundation
import Testing

@testable import amanuensis

/// Which processes count as "a call is happening", and which of them the
/// system-audio tap should follow. Both decisions are whitelist-shaped, and
/// both are wrong in expensive ways: a false positive records the room, a
/// false negative loses the far end.
struct CallAppDetectionTests {
    private func process(
        _ bundleID: String,
        name: String,
        object: UInt32 = 1,
        input: Bool = false,
        output: Bool = false
    ) -> AudioProcesses.Process {
        AudioProcesses.Process(
            object: object, pid: 100, bundleID: bundleID, name: name,
            runningInput: input, runningOutput: output)
    }

    private let callApps = ["us.zoom.xos", "com.google.Chrome"]

    @Test("A listed call app on the mic is a meeting")
    func listedAppCounts() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("us.zoom.xos", name: "zoom.us", input: true)],
            callApps: callApps)

        #expect(result.active)
        #expect(result.names == ["zoom.us"])
        #expect(result.families == ["us.zoom.xos"])
    }

    /// The process that opens the mic is usually a helper, and the tap has to
    /// follow the whole app: point it at one renderer and a reloaded tab takes
    /// the far end with it.
    @Test("A helper process resolves to its app's family")
    func helperResolvesToFamily() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("com.google.Chrome.helper.Renderer",
                                name: "Google Chrome Helper", input: true)],
            callApps: callApps)

        #expect(result.active)
        #expect(result.families == ["com.google.Chrome"])
    }

    @Test("An app that isn't a call app is seen but doesn't start anything")
    func unlistedAppIsVisibleButInert() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("com.apple.Terminal", name: "Terminal", input: true)],
            callApps: callApps)

        #expect(!result.active)
        #expect(result.families.isEmpty)
        // Still reported, so the menu can say why nothing is being recorded.
        #expect(result.allHolders == ["Terminal"])
    }

    /// Dictation holds the mic for exactly as long as you speak, which no
    /// timing rule can tell from a call. It is never a meeting, whatever the
    /// whitelist says.
    @Test("Dictation is never a meeting even when everything counts")
    func dictationIsAlwaysIgnored() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("com.prakashjoshipax.VoiceInk", name: "VoiceInk", input: true)],
            callApps: [])

        #expect(!result.active)
    }

    @Test("An empty whitelist means any app counts")
    func emptyWhitelistCountsEverything() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("com.example.Unknown", name: "Unknown", input: true)],
            callApps: [])

        #expect(result.active)
        #expect(result.families == ["com.example.Unknown"])
    }

    @Test("ignore_apps wins over the whitelist")
    func ignoreListWins() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("us.zoom.xos", name: "zoom.us", input: true)],
            callApps: callApps,
            ignoring: ["us.zoom.xos"])

        #expect(!result.active)
    }

    @Test("A process with no bundle id is matched by its executable name")
    func bundlelessProcessMatchesByName() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("", name: "ffmpeg", input: true)],
            callApps: ["ffmpeg"])

        #expect(result.active)
        #expect(result.families == ["ffmpeg"])
    }

    /// What the tap follows: every process of the app, including the ones not
    /// making a sound yet, and nothing belonging to anybody else.
    @Test("The tap follows the whole app family and nothing else")
    func tapSelectionCoversTheFamily() {
        let processes = [
            process("com.google.Chrome", name: "Google Chrome", object: 1),
            process("com.google.Chrome.helper.Renderer", name: "Chrome Helper", object: 2,
                    output: true),
            process("com.spotify.client", name: "Spotify", object: 3, output: true),
            process("", name: "afplay", object: 4, output: true),
        ]

        let selected = AudioProcesses.matching(families: ["com.google.Chrome"], in: processes)

        #expect(selected.map(\.object) == [1, 2])
    }

    @Test("With no family to follow, the tap selects nothing and falls back")
    func emptyFamiliesSelectNothing() {
        let processes = [process("com.spotify.client", name: "Spotify", output: true)]
        #expect(AudioProcesses.matching(families: [], in: processes).isEmpty)
    }
}
