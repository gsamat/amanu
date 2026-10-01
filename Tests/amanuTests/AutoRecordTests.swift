import Foundation
import Testing

@testable import amanu

/// When an automatic recording is thrown away instead of kept.
///
/// The rule is arithmetic, and the arithmetic was wrong for as long as it was
/// only ever evaluated inside the method that stops a session: every stop
/// reason has to wait out a quiet period before it can fire, so a recording
/// compared whole against the minimum was always longer than the minimum and
/// nothing was ever discarded (`.issues/008`). These are the cases that were
/// measured on real calls, plus one floor per reason.
struct AutoRecordTests {
    private let settings = Config.AutoRecordSettings()

    /// The case from the issue: nineteen seconds of Zoom, then ninety seconds
    /// of amanu waiting to be sure the call was over, kept as a 99-second
    /// recording with 29 MB of audio and nothing in it.
    ///
    /// The wait it was measured under is written here rather than taken from
    /// the defaults, which are now fifteen seconds: the point of the case is the
    /// arithmetic, and it should keep failing the way it failed then no matter
    /// what the default becomes.
    @Test("A nineteen-second join is thrown away despite the wait that follows it")
    func shortJoinIsDiscarded() {
        var measured = settings
        measured.stopDelay = 90

        #expect(AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended", duration: 99, settings: measured))
    }

    @Test("A real meeting is kept")
    func realMeetingIsKept() {
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended", duration: 45 * 60, settings: settings))
    }

    /// If you pressed the button, nine seconds of it were nine seconds you
    /// meant. The guard is on the trigger, not on the reason, so it holds even
    /// when a manual recording happens to be stopped by one of the auto rules.
    @Test("A nine-second manual recording is kept")
    func manualIsNeverDiscarded() {
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .manual, reason: "manual", duration: 9, settings: settings))
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .manual, reason: "call-ended", duration: 9, settings: settings))
    }

    /// Each stop reason waits out a different quiet period, and each of those
    /// waits used to be enough on its own to push the recording past the
    /// minimum. One case per reason, at ten seconds of actual meeting.
    @Test("Every reason that ends by itself has its own wait taken out")
    func everyReasonHasItsFloorRemoved() {
        #expect(AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended",
            duration: settings.stopDelay + 10, settings: settings))
        #expect(AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "silence",
            duration: settings.silenceStop + 10, settings: settings))
        #expect(AutoRecordController.shouldDiscard(
            trigger: .calendar, reason: "calendar-event-ended",
            duration: AutoRecordController.calendarEndQuiet + 10, settings: settings))
    }

    /// The same three waits, with a meeting long enough to keep on the other
    /// side of them — so the subtraction cannot be mistaken for "discard
    /// anything that ended by itself".
    @Test("A long enough meeting survives every reason")
    func longEnoughMeetingsSurviveEveryReason() {
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended",
            duration: settings.stopDelay + 20 * 60, settings: settings))
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "silence",
            duration: settings.silenceStop + 20 * 60, settings: settings))
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .calendar, reason: "calendar-event-ended",
            duration: AutoRecordController.calendarEndQuiet + 20 * 60, settings: settings))
    }

    /// "Shorter than" is what the setting says, so a meeting of exactly the
    /// minimum is kept and one second less is not.
    @Test("The minimum itself is kept and a second under it is not")
    func boundaryIsExclusive() {
        #expect(!AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended",
            duration: settings.stopDelay + settings.minDuration, settings: settings))
        #expect(AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended",
            duration: settings.stopDelay + settings.minDuration - 1, settings: settings))
    }

    /// "app-quit" and "max-duration" say only that we stopped the recording,
    /// which is no evidence about whether a meeting was happening. Discarding
    /// on those threw away the first fifteen seconds of a genuine call that
    /// started while amanu was being reinstalled.
    @Test("A recording we ended ourselves is never discarded")
    func reasonsWeChoseAreKept() {
        for reason in ["app-quit", "max-duration", "manual", "system-sleep"] {
            #expect(!AutoRecordController.shouldDiscard(
                trigger: .micActivity, reason: reason, duration: 5, settings: settings))
        }
    }

    /// The waits are settings, not constants, so someone who lengthens the
    /// stop delay does not thereby start keeping short joins again.
    @Test("A tuned stop delay comes out of the length in the same way")
    func waitsFollowTheSettings() {
        var patient = Config.AutoRecordSettings()
        patient.stopDelay = 300

        #expect(AutoRecordController.shouldDiscard(
            trigger: .micActivity, reason: "call-ended", duration: 310, settings: patient))
        #expect(AutoRecordController.trailingQuiet(for: "call-ended", settings: patient) == 300)
        #expect(AutoRecordController.trailingQuiet(for: "app-quit", settings: patient) == nil)
    }
}

@MainActor
struct ManualStopAutoRecordTests {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test("The default start waits three seconds rather than losing twelve seconds of the call")
    func defaultStartWaitsThreeSeconds() {
        let clock = Clock()
        let settings = Config.AutoRecordSettings()
        var starts = 0
        let controller = AutoRecordController(
            settings: settings,
            calendar: nil,
            loadSettings: { settings },
            checkMic: { _ in
                MicActivityMonitor.Result(active: true, names: ["zoom.us"],
                    families: ["us.zoom.xos"], allHolders: ["zoom.us"])
            },
            now: { clock.date }
        )
        controller.startRecording = { _, _ in starts += 1; return true }
        controller.tick()
        clock.date.addTimeInterval(2)
        controller.tick()
        #expect(starts == 0)
        clock.date.addTimeInterval(1)
        controller.tick()
        #expect(starts == 1)
    }

    private func controller(
        clock: Clock,
        micActive: @escaping () -> Bool,
        onStart: @escaping () -> Void
    ) -> AutoRecordController {
        var settings = Config.AutoRecordSettings()
        settings.startDelay = 0
        settings.stopDelay = 15
        let controller = AutoRecordController(
            settings: settings,
            calendar: nil,
            loadSettings: { settings },
            checkMic: { _ in
                MicActivityMonitor.Result(
                    active: micActive(),
                    names: micActive() ? ["zoom.us"] : [],
                    families: micActive() ? ["us.zoom.xos"] : [],
                    allHolders: micActive() ? ["zoom.us"] : []
                )
            },
            now: { clock.date }
        )
        controller.startRecording = { _, _ in onStart(); return true }
        return controller
    }

    @Test("A manual stop does not expire while the same call stays active")
    func manualStopDoesNotExpireDuringCall() {
        let clock = Clock()
        var starts = 0
        let controller = controller(clock: clock, micActive: { true }) { starts += 1 }

        controller.noteManualStop()
        clock.date.addTimeInterval(60 * 60)
        controller.tick()

        #expect(starts == 0)
    }

    @Test("Automatic recording rearms after the manually stopped call ends")
    func manualStopRearmsAfterCallEnds() {
        let clock = Clock()
        var active = true
        var starts = 0
        let controller = controller(clock: clock, micActive: { active }) { starts += 1 }

        controller.noteManualStop()
        active = false
        controller.tick()
        clock.date.addTimeInterval(16)
        controller.tick()
        active = true
        controller.tick()

        #expect(starts == 1)
    }
}

// MARK: - the loop, tick by tick

@MainActor
final class FakeAutoSession: AutoRecordedSession {
    let startedAt: Date
    let trigger: RecordingSession.Trigger
    var lastMicSoundAt: Date?
    var lastSystemSoundAt: Date?
    var levelsMeasurable = true

    init(startedAt: Date, trigger: RecordingSession.Trigger) {
        self.startedAt = startedAt
        self.trigger = trigger
    }
}

@MainActor
final class FakeCalendar: MeetingCalendar {
    var meetings: [CalendarWatcher.Meeting] = []

    func justStarted(now: Date, window: TimeInterval) -> [CalendarWatcher.Meeting] {
        meetings.filter {
            let since = now.timeIntervalSince($0.start)
            return since >= -30 && since <= window && $0.looksLikeCall
        }
    }

    func bestMatch(for date: Date) -> CalendarWatcher.Meeting? {
        meetings.first { $0.start <= date && $0.end >= date }
    }

    static func meeting(id: String, start: Date, minutes: Double = 30) -> CalendarWatcher.Meeting {
        CalendarWatcher.Meeting(
            id: id, title: "Weekly", start: start, end: start.addingTimeInterval(minutes * 60),
            attendees: ["a", "b"], link: nil, looksLikeCall: true)
    }
}

/// A controller wired to a clock, a microphone and a recorder that are all
/// just variables, ticked the way the real timer ticks it: every five seconds.
@MainActor
final class AutoRecordHarness {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var micActive = false
    var settings = Config.AutoRecordSettings()
    var session: FakeAutoSession?
    var refuseStarts = false
    private(set) var attempts: [RecordingSession.Trigger] = []
    private(set) var starts: [RecordingSession.Trigger] = []
    private(set) var stops: [String] = []
    private(set) var saved: [Bool] = []
    var controller: AutoRecordController!

    init(calendar: MeetingCalendar? = nil, configure: (inout Config.AutoRecordSettings) -> Void = { _ in }) {
        configure(&settings)
        controller = AutoRecordController(
            settings: settings,
            calendar: calendar,
            loadSettings: { [unowned self] in settings },
            saveEnabled: { [unowned self] on in
                saved.append(on)
                settings.enabled = on
                return true
            },
            checkMic: { [unowned self] _ in
                MicActivityMonitor.Result(
                    active: micActive,
                    names: micActive ? ["zoom.us"] : [],
                    families: micActive ? ["us.zoom.xos"] : [],
                    allHolders: micActive ? ["zoom.us"] : [])
            },
            now: { [unowned self] in now })
        controller.currentSession = { [unowned self] in session }
        controller.startRecording = { [unowned self] trigger, _ in
            attempts.append(trigger)
            guard !refuseStarts else { return false }
            starts.append(trigger)
            session = FakeAutoSession(startedAt: now, trigger: trigger)
            return true
        }
        controller.stopRecording = { [unowned self] reason in
            stops.append(reason)
            session = nil
        }
    }

    /// Tick every five seconds for `seconds`, calling `each` before each tick.
    func run(for seconds: TimeInterval, each: () -> Void = {}) {
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            now.addTimeInterval(5)
            elapsed += 5
            each()
            controller.tick()
        }
    }
}

@MainActor
struct AutoRecordLoopTests {
    /// The backstop exists for an app that never lets go of the microphone.
    /// It used to stop the recording and, five seconds later, see the same
    /// app on the mic for longer than the start delay and start again —
    /// every two hours, or every ten minutes of silence, forever.
    @Test("A backstop stop is not followed by a new recording while the mic is still held",
          arguments: ["max-duration", "silence"])
    func backstopDoesNotRearm(reason: String) {
        let h = AutoRecordHarness {
            $0.maxDuration = 60 * 60
            $0.silenceStop = reason == "silence" ? 10 * 60 : 24 * 60 * 60
        }
        h.micActive = true
        h.run(for: 20)
        #expect(h.starts == [.micActivity])

        h.run(for: 2 * 60 * 60)
        #expect(h.stops == [reason])
        #expect(h.starts.count == 1, "restarted \(h.starts.count - 1) time(s) behind its own backstop")
        #expect(h.controller.phase == .standingDown(.backstop(reason)))

        // Let go of the mic for longer than the stop delay, and the next call
        // is a new one.
        h.micActive = false
        h.run(for: h.settings.stopDelay + 15)
        h.micActive = true
        h.run(for: 20)
        #expect(h.starts.count == 2)
    }

    @Test("The ceiling stops a manual recording and does not hand the call to auto-record")
    func manualRecordingAtTheCeiling() {
        let h = AutoRecordHarness { $0.maxDuration = 60 * 60 }
        h.micActive = true
        h.session = FakeAutoSession(startedAt: h.now, trigger: .manual)
        h.run(for: 61 * 60)
        #expect(h.stops == ["max-duration"])
        h.run(for: 30 * 60)
        #expect(h.starts.isEmpty)
    }

    /// The ceiling sat behind the auto-record switch, so with the switch off
    /// a recording started by hand and forgotten ran until the disk filled.
    @Test("The ceiling stops a recording with auto-record off as well")
    func ceilingWithAutoRecordOff() {
        let h = AutoRecordHarness {
            $0.enabled = false
            $0.maxDuration = 60 * 60
        }
        h.session = FakeAutoSession(startedAt: h.now, trigger: .manual)
        h.run(for: 61 * 60)
        #expect(h.stops == ["max-duration"])
        #expect(h.starts.isEmpty)
    }

    /// "Can't measure" and "silent" look identical to the meter, and only
    /// one of them should end a meeting.
    @Test("The silence backstop stands down when levels cannot be measured")
    func silenceNeedsMeasurableLevels() {
        let h = AutoRecordHarness { $0.silenceStop = 10 * 60 }
        h.micActive = true
        h.session = FakeAutoSession(startedAt: h.now, trigger: .micActivity)
        h.session?.levelsMeasurable = false
        h.run(for: 30 * 60)
        #expect(h.stops.isEmpty)

        h.session?.levelsMeasurable = true
        h.run(for: 10)
        #expect(h.stops == ["silence"])
    }

    @Test("A call does not count as ended while the far end is still talking")
    func farEndKeepsTheCallAlive() {
        let h = AutoRecordHarness()
        h.micActive = true
        h.run(for: 20)
        h.micActive = false
        h.run(for: 5 * 60) { h.session?.lastSystemSoundAt = h.now }
        #expect(h.stops.isEmpty)

        h.run(for: h.settings.stopDelay + 10)
        #expect(h.stops == ["call-ended"])
        #expect(h.controller.phase == .watching)
    }

    @Test("A finished calendar event ends the recording once the far end is quiet")
    func calendarEventEnded() {
        let calendar = FakeCalendar()
        let h = AutoRecordHarness(calendar: calendar) {
            $0.calendar = true
            $0.stopDelay = 60 * 60
        }
        calendar.meetings = [FakeCalendar.meeting(id: "sync", start: h.now.addingTimeInterval(5), minutes: 5)]
        h.run(for: 10)
        #expect(h.starts == [.calendar])

        h.micActive = true
        h.run(for: 4 * 60) { h.session?.lastSystemSoundAt = h.now }
        h.micActive = false
        h.run(for: 60)
        #expect(h.stops.isEmpty, "The event is not over yet.")
        h.run(for: 4 * 60)
        #expect(h.stops == ["calendar-event-ended"])
    }

    /// The event starts the recording on time; people join late. The mic
    /// had been idle since long before, so the old rule called the call over
    /// twenty seconds in.
    @Test("A calendar recording waits for someone to join before the call can end")
    func calendarRecordingWaitsToBeJoined() {
        let calendar = FakeCalendar()
        let h = AutoRecordHarness(calendar: calendar) {
            $0.calendar = true
            $0.silenceStop = 24 * 60 * 60
        }
        h.run(for: 60)
        calendar.meetings = [FakeCalendar.meeting(id: "sync", start: h.now, minutes: 60)]
        h.run(for: 30)
        #expect(h.starts == [.calendar])

        h.run(for: 5 * 60)
        #expect(h.stops.isEmpty)

        h.micActive = true
        h.run(for: 60)
        h.micActive = false
        h.run(for: h.settings.stopDelay + 10)
        #expect(h.stops == ["call-ended"])
    }

    @Test("The wait for a calendar meeting to be joined is bounded")
    func calendarJoinGraceIsBounded() {
        let calendar = FakeCalendar()
        let h = AutoRecordHarness(calendar: calendar) {
            $0.calendar = true
            $0.silenceStop = 24 * 60 * 60
        }
        calendar.meetings = [FakeCalendar.meeting(id: "sync", start: h.now.addingTimeInterval(5), minutes: 60)]
        h.run(for: 5)
        h.run(for: AutoRecordController.calendarJoinGrace + 10)
        #expect(h.stops == ["call-ended"])
    }

    /// Every occurrence of a recurring event shares one identifier, so
    /// remembering the identifier skipped the series from its second week.
    @Test("Each occurrence of a recurring event starts its own recording")
    func recurringEventsRecordEveryTime() {
        let calendar = FakeCalendar()
        let h = AutoRecordHarness(calendar: calendar) {
            $0.calendar = true
            $0.micActivity = false
        }
        calendar.meetings = [FakeCalendar.meeting(id: "weekly", start: h.now.addingTimeInterval(5))]
        h.run(for: 5)
        #expect(h.starts == [.calendar])
        h.session = nil

        h.now.addTimeInterval(7 * 24 * 60 * 60)
        calendar.meetings = [FakeCalendar.meeting(id: "weekly", start: h.now.addingTimeInterval(5))]
        h.run(for: 30)
        #expect(h.starts == [.calendar, .calendar])
    }

    /// A refused start used to be retried on the next tick, every five
    /// seconds, each with a new banner and a new empty folder.
    @Test("A refused start backs off instead of retrying every tick")
    func refusedStartBacksOff() {
        let h = AutoRecordHarness()
        h.refuseStarts = true
        h.micActive = true
        h.run(for: 5 * 60)
        // 15 s to the first try, then 30 s, 60 s, 120 s: four in five minutes,
        // where every tick would have been fifty-seven.
        #expect(h.attempts.count == 4)
        if case .backingOff = h.controller.phase {} else {
            Issue.record("expected to be backing off, was \(h.controller.phase)")
        }

        // A working device on the next try is picked up at the next retry.
        h.refuseStarts = false
        h.run(for: 5 * 60)
        #expect(h.starts == [.micActivity])
    }

    @Test("Retry waits double up to a ceiling")
    func retryDelays() {
        #expect(AutoRecordController.retryDelay(afterFailures: 1) == 30)
        #expect(AutoRecordController.retryDelay(afterFailures: 2) == 60)
        #expect(AutoRecordController.retryDelay(afterFailures: 5) == 480)
        #expect(AutoRecordController.retryDelay(afterFailures: 6) == 600)
        #expect(AutoRecordController.retryDelay(afterFailures: 60) == 600)
    }

    /// The switch lives in the config file. Turned on in Settings while the
    /// app was running with it off, it used to do nothing until a relaunch
    /// while the window showed it on.
    @Test("Auto-record follows auto_record.enabled while running")
    func switchFollowsTheConfig() {
        let h = AutoRecordHarness { $0.enabled = false }
        h.micActive = true
        h.run(for: 60)
        #expect(h.starts.isEmpty)
        #expect(!h.controller.enabled)

        h.settings.enabled = true
        h.controller.reloadSettings()
        #expect(h.controller.enabled)
        h.run(for: 20)
        #expect(h.starts == [.micActivity])
    }

    @Test("The menu switch writes the config and reads it back")
    func menuSwitchWritesTheConfig() {
        let h = AutoRecordHarness()
        h.controller.setEnabled(false)
        #expect(h.saved == [false])
        #expect(!h.controller.enabled)
        h.micActive = true
        h.run(for: 60)
        #expect(h.starts.isEmpty)
        #expect(h.controller.lastDecision == "auto-record off")

        h.controller.setEnabled(true)
        #expect(h.saved == [false, true])
        h.run(for: 20)
        #expect(h.starts == [.micActivity])
    }

    /// The timer does not tick while the Mac sleeps, so a mic clock kept from
    /// before the sleep reads the whole sleep as the mic being held.
    @Test("After sleep the mic has to be held for the full start delay again")
    func sleepResetsTheMicClock() {
        let h = AutoRecordHarness()
        h.micActive = true
        h.run(for: 5)
        h.controller.noteSystemSleep()
        h.now.addTimeInterval(8 * 60 * 60)
        h.run(for: 5)
        #expect(h.starts.isEmpty)
        h.run(for: 15)
        #expect(h.starts == [.micActivity])
    }
}
