import Foundation
import Testing
@testable import amanu

/// The rule these pin down is the one that cannot be tested by hand without
/// waiting a day for Sparkle's timer and then holding a real meeting to see
/// what it does.
@MainActor
@Suite("An update never interrupts a recording")
struct UpdateGateTests {
    @Test("A scheduled check waits until the recording is over")
    func backgroundCheckDefersToRecording() {
        var recording = true
        let gate = UpdateGate(isRecording: { recording })

        #expect(!gate.mayCheck(.background))
        recording = false
        #expect(gate.mayCheck(.background))
    }

    @Test("Asking from the menu is answered even mid-meeting")
    func userInitiatedCheckIsAlwaysAllowed() {
        let gate = UpdateGate(isRecording: { true })

        // Finding out costs nothing; it is installing that is dangerous, and
        // that is gated separately.
        #expect(gate.mayCheck(.userInitiated))
        #expect(gate.mayCheck(.informationOnly))
    }

    @Test("An install offered during a recording is held, then runs when it ends")
    func installIsPostponedUntilTheRecordingStops() {
        var recording = true
        let gate = UpdateGate(isRecording: { recording })

        var installed = 0
        #expect(gate.postponeInstallIfRecording { installed += 1 })
        #expect(gate.hasPostponedInstall)
        #expect(installed == 0)

        recording = false
        gate.recordingDidFinish()
        #expect(installed == 1)
        #expect(!gate.hasPostponedInstall)
    }

    @Test("Held installs run once, not once per recording that ends afterwards")
    func aPostponedInstallIsNotRunTwice() {
        let gate = UpdateGate(isRecording: { true })
        var installed = 0
        _ = gate.postponeInstallIfRecording { installed += 1 }

        gate.recordingDidFinish()
        gate.recordingDidFinish()
        #expect(installed == 1)
    }

    @Test("With nothing recording the installer is not held at all")
    func idleInstallProceedsImmediately() {
        let gate = UpdateGate(isRecording: { false })

        // False means "don't wait for me" — Sparkle goes ahead on its own, so
        // the handler must not be stored, or the update would never install.
        #expect(!gate.postponeInstallIfRecording { Issue.record("must not be kept") })
        #expect(!gate.hasPostponedInstall)
        gate.recordingDidFinish()
    }
}
