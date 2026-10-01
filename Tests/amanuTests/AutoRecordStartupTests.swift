import AppKit
import Foundation
import Testing

@testable import amanu

@MainActor
@Suite(.serialized, .freshHome)
struct AutoRecordStartupTests {
    @Test("An unfinished setup does not prevent the app from watching a granted microphone")
    func pendingSetupStillWatchesMeetings() {
        #expect(SetupState.isPending)
        var settings = Config.AutoRecordSettings()
        settings.startDelay = 3600
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in Self.zoom }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let app = AppController(root: Home.current.defaultRecordings, autoRecord: watcher)
        defer {
            watcher.stop()
            app.finishForTermination()
            for window in NSApp.windows { window.orderOut(nil) }
        }
        #expect(watcher.lastDecision == "zoom.us on the mic for 0s")
        #expect(SetupState.isPending, "watching must not silently complete the setup wizard")
    }

    @Test("Both triggers wait for microphone access without requesting a recording or backing off",
          arguments: [false, true])
    func microphoneGrantUnblocksWatching(fromCalendar: Bool) {
        var settings = Config.AutoRecordSettings()
        settings.startDelay = 0
        settings.calendar = fromCalendar
        let calendar = FakeCalendar()
        calendar.meetings = [FakeCalendar.meeting(id: "sync", start: Date())]
        var granted = false
        var attempts = 0
        let watcher = AutoRecordController(
            settings: settings, calendar: calendar, loadSettings: { settings },
            canStartRecording: { granted }, checkMic: { _ in Self.zoom })
        watcher.startRecording = { _, _ in attempts += 1; return true }
        watcher.tick()
        #expect(attempts == 0)
        #expect(watcher.phase == .watching)
        #expect(watcher.lastDecision == "waiting for microphone access")
        granted = true
        watcher.tick()
        #expect(attempts == 1)
        #expect(watcher.phase == .recording)
    }

    @Test("Starting a disabled watcher reports its state immediately")
    func disabledStateIsVisibleAtStartup() {
        var settings = Config.AutoRecordSettings()
        settings.enabled = false
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings })
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lastDecision == "auto-record off")
    }

    @Test("The real timer starts a held Zoom microphone within the three-second default delay")
    func timerUsesShortStartDelay() {
        let settings = Config.AutoRecordSettings()
        var session: FakeAutoSession?
        var started: Date?
        let watcher = AutoRecordController(
            settings: settings, calendar: nil, loadSettings: { settings },
            checkMic: { _ in Self.zoom })
        watcher.currentSession = { session }
        watcher.startRecording = { trigger, _ in
            started = Date()
            session = FakeAutoSession(startedAt: Date(), trigger: trigger)
            return true
        }
        let beganWatching = Date()
        watcher.start()
        defer { watcher.stop() }
        RunLoop.current.run(until: beganWatching.addingTimeInterval(2))
        #expect(started == nil)
        let deadline = beganWatching.addingTimeInterval(4.5)
        while started == nil, Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.02)))
        }
        #expect(started != nil, "a five-second poll misses the configured three-second delay")
    }

    private static var zoom: MicActivityMonitor.Result {
        MicActivityMonitor.Result(active: true, names: ["zoom.us"],
            families: ["us.zoom.xos"], allHolders: ["zoom.us"])
    }
}
