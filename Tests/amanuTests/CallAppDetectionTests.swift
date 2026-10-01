import Foundation
import Testing

@testable import amanu

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

    /// These are defaults rather than setup advice: without their bundle-id
    /// family, a call in one of these apps or browsers never starts a recording.
    @Test("Popular call apps and browsers start automatic recording", arguments: [
        "net.whatsapp.WhatsApp",
        "org.whispersystems.signal-desktop",
        "com.microsoft.teams2",
        "com.tdesktop.Telegram",
        "Cisco-Systems.Spark",
        "com.viber.osx",
        "jp.naver.line.mac",
        "com.tencent.xinWeChat",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
        "ru.yandex.desktop.yandex-browser",
        "com.duckduckgo.macos.browser",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "company.thebrowser.dia",
        "ai.perplexity.comet.helper",
        "ru.yandex.desktop.telemost",
        "ru.unlimitedtech.express.desktop",
        "kontur.talk",
        "vc.dion.desktop",
    ])
    func popularCallAppsAndBrowsersCount(bundleID: String) {
        let result = MicActivityMonitor.evaluate(
            processes: [process(bundleID, name: "Call", input: true)],
            callApps: MicActivityMonitor.defaultCallApps)

        #expect(result.active)
        #expect(!result.families.isEmpty)
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

    @Test("A browser or helper name enables recording and follows the whole browser",
          arguments: ["Comet", "Comet Helper", " comet "])
    func browserNamesCount(entry: String) {
        let processes = [
            process("ai.perplexity.comet", name: "Comet", object: 1),
            process("ai.perplexity.comet.helper", name: "Comet Helper", object: 2, input: true),
            process("ai.perplexity.comet.helper.Renderer", name: "Comet Helper (Renderer)",
                    object: 3, output: true),
            process("com.spotify.client", name: "Spotify", object: 4, output: true),
        ]
        let result = MicActivityMonitor.evaluate(processes: processes, callApps: [entry])

        #expect(result.active)
        #expect(result.families == ["ai.perplexity.comet"])
        #expect(AudioProcesses.matching(families: result.families, in: processes)
            .map(\.object) == [1, 2, 3])
    }

    @Test("An app with a bundle id can be listed by its display name")
    func bundledAppMatchesByName() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("com.example.Calls", name: "Calls", input: true)],
            callApps: ["Calls"])
        #expect(result.active)
        #expect(result.families == ["com.example.Calls"])
    }

    @Test("App names do not match unrelated names or empty entries",
          arguments: ["Com", "Cometary", "Comet Helperish", "", " "])
    func similarNamesDoNotCount(entry: String) {
        let result = MicActivityMonitor.evaluate(
            processes: [process("ai.perplexity.comet.helper", name: "Comet Helper", input: true)],
            callApps: [entry])
        #expect(!result.active)
    }

    @Test("A browser name covers helpers with a Chromium role suffix")
    func namedBrowserCoversRenderer() {
        let result = MicActivityMonitor.evaluate(
            processes: [process("ai.perplexity.comet.helper.Renderer",
                                name: "Comet Helper (Renderer)", input: true)],
            callApps: ["Comet"])
        #expect(result.active)
        #expect(result.families == ["ai.perplexity.comet"])
    }

    @MainActor
    @Test("A configured browser name starts recording after the microphone delay")
    func namedBrowserStartsRecording() {
        var settings = Config.AutoRecordSettings()
        settings.callApps = ["Comet"]
        settings.calendar = false
        settings.startDelay = 10
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var starts: [RecordingSession.Trigger] = []
        var capturedFamilies: [String] = []
        let processes = [process("ai.perplexity.comet.helper", name: "Comet Helper", input: true)]
        let controller = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { MicActivityMonitor.evaluate(processes: processes, callApps: $0.callApps) },
            now: { now })
        controller.startRecording = { trigger, context in
            starts.append(trigger)
            capturedFamilies = context.appFamilies
            return true
        }
        controller.tick()
        #expect(starts.isEmpty)
        now.addTimeInterval(10)
        controller.tick()
        #expect(starts == [.micActivity])
        #expect(capturedFamilies == ["ai.perplexity.comet"])
    }

    @Test("The any-app switch bypasses the call list and preserves exclusions", .freshHome)
    func anyAppSwitch() throws {
        try Home.current.writeConfig([
            "auto_record": ["apps": ["us.zoom.xos"], "ignore_apps": ["Ignored"]],
        ])
        let entry = try #require(SettingsSchema.everyEntry.first {
            $0.path == ["auto_record", "any_app"]
        })
        let unknown = process("com.example.Unknown", name: "Unknown", input: true)
        #expect(!MicActivityMonitor.evaluate(
            processes: [unknown], callApps: Config.autoRecord().callApps).active)

        guard case .set(let value) = SettingsSchema.resolve(.flag(true), for: entry) else {
            Issue.record("The switch must save the enabled mode")
            return
        }
        #expect(Config.update(path: entry.path, value: value))
        let settings = Config.autoRecord()
        #expect(settings.callApps.isEmpty)
        #expect(MicActivityMonitor.evaluate(processes: [unknown], callApps: settings.callApps).active)
        #expect(!MicActivityMonitor.evaluate(
            processes: [process("com.example.Ignored", name: "Ignored", input: true)],
            callApps: settings.callApps, ignoring: settings.ignoreApps).active)
        #expect(!MicActivityMonitor.evaluate(
            processes: [process("com.prakashjoshipax.VoiceInk", name: "VoiceInk", input: true)],
            callApps: settings.callApps).active)

        #expect(Config.update(path: entry.path, value: nil))
        #expect(Config.autoRecord().callApps == ["us.zoom.xos"])
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
