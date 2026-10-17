import Foundation
import Testing
@testable import amanu

/// Whether the Mac may sleep is a property of the whole machine, and the only
/// way to see it by hand is to leave a laptop open overnight and read the
/// battery in the morning — so the bits that decide it are checked here.
@Suite("The Mac idle-sleeps between meetings")
struct WakefulnessTests {
    @Test("Waiting for a meeting does not keep the Mac awake")
    func lifetimeAllowsIdleSleep() {
        // `.userInitiated` does keep App Nap away, but it also carries
        // `.idleSystemSleepDisabled`; the variant checked for below is the same
        // set without that one bit.
        #expect(!Wakefulness.lifetime.contains(.idleSystemSleepDisabled))
        #expect(Wakefulness.lifetime.contains(.userInitiatedAllowingIdleSystemSleep))
        #expect(Wakefulness.lifetime.contains(.suddenTerminationDisabled))
        #expect(Wakefulness.lifetime.contains(.automaticTerminationDisabled))
    }

    @Test("Recording and transcribing both keep the Mac awake")
    func meetingsHoldSleepOff() {
        #expect(Wakefulness.recording.contains(.idleSystemSleepDisabled))
        #expect(Wakefulness.transcribing.contains(.idleSystemSleepDisabled))
    }
}

/// Stands in for the power manager: counts the holds a coordinator takes and
/// gives back, so a test can say how many were outstanding at a moment without
/// asking the machine, which would answer for every other process on it too.
private final class HoldCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var taken = 0

    var held: Int { lock.lock(); defer { lock.unlock() }; return outstanding }
    var begun: Int { lock.lock(); defer { lock.unlock() }; return taken }

    func hold() -> Wakefulness.Hold {
        return { _ in
            self.lock.lock()
            self.outstanding += 1
            self.taken += 1
            self.lock.unlock()
            return {
                self.lock.lock()
                self.outstanding -= 1
                self.lock.unlock()
            }
        }
    }
}

/// What the queue does with the Mac's sleep while it works. The state worth
/// asserting is the one after `waitUntilIdle`: a status handler hears `.idle`
/// before the drain has returned, so a test that stopped there would look at
/// a hold that was about to be given back and call it a leak.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct DrainWakefulnessTests {
    @Test("The queue holds sleep off while it transcribes and gives it back when it is done")
    func holdLastsExactlyAsLongAsTheDrain() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        try recordings.session("2026-09-28 10-00")
        let holds = HoldCounter()
        let heldDuringWork = LockedList()
        let engine = FakeEngine("parakeet", answer: { audio, call in
            heldDuringWork.append(holds.held)
            return try FakeEngine.speech(audio, call)
        })
        let coordinator = TranscriptionCoordinator(
            engine: engine, onStop: { nil }, keepAwake: holds.hold())

        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()

        #expect(!heldDuringWork.values.isEmpty)
        #expect(heldDuringWork.values.allSatisfy { $0 == 1 }, "\(heldDuringWork.values)")
        #expect(holds.begun >= 1)
        #expect(holds.held == 0)
    }
}

/// Numbers noted from inside an engine, which runs on whatever thread the
/// coordinator gave it.
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []

    func append(_ value: Int) { lock.lock(); items.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}
