import Foundation
import Testing
@testable import amanu

/// The rule here is the one that can only be tested by hand by holding a real
/// meeting and then pressing ⌘Q to see what happens — which is exactly the
/// experiment nobody wants to run twice.
@MainActor
@Suite("Quitting never interrupts a recording in silence")
struct QuitGateTests {
    @Test("With nothing recording the quit goes straight through")
    func idleQuitIsNotQuestioned() {
        // An alert on every quit would be a nuisance that teaches people to
        // dismiss it, which is the one thing that would make this worse.
        #expect(QuitGate(recordingElapsed: { nil }).decide() == .quitNow)
        #expect(QuitGate().decide() == .quitNow)
    }

    @Test("A recording turns the quit into a question carrying its length")
    func recordingQuitAsksFirst() {
        let gate = QuitGate(recordingElapsed: { 252 })

        // The elapsed time travels with the decision because it is what the
        // alert has to say: "4:12" is the difference between an informed
        // choice and a dialog someone clicks through.
        #expect(gate.decide() == .ask(elapsed: 252))
        #expect(AppController.format(252) == "4:12")
    }

    @Test("The answer is taken at the moment of the quit, not at set-up")
    func theDecisionIsAskedFreshEachTime() {
        var elapsed: TimeInterval?
        let gate = QuitGate(recordingElapsed: { elapsed })

        #expect(gate.decide() == .quitNow)
        elapsed = 30
        #expect(gate.decide() == .ask(elapsed: 30))
        elapsed = nil
        #expect(gate.decide() == .quitNow)
    }
}
