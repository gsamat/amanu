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
        for reason in ["app-quit", "max-duration", "manual"] {
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
        controller.startRecording = { _, _ in onStart() }
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
