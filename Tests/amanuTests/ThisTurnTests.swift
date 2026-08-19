import Foundation
import Testing
@testable import amanu

/// The memo behind every grant the setup window draws. What it has to get
/// right is the forgetting: an answer kept a moment too long is a window
/// saying the microphone is still not allowed after someone has just allowed
/// it, which is worse than the milliseconds it saves.
@Suite(.serialized)
struct ThisTurnTests {
    @Test("One turn asks the machine once; the next turn asks again")
    @MainActor
    func askedOncePerTurn() async {
        var asks = 0
        func ask() -> Int { ThisTurn.answer("test.asked-once") { asks += 1; return asks } }

        #expect(ask() == 1)
        #expect(ask() == 1)
        #expect(asks == 1)

        // Anything that lets the main queue run is a new turn — and a person
        // cannot change a grant without one, since it takes System Settings.
        await Task.yield()
        #expect(ask() == 2)
        #expect(asks == 2)
    }

    @Test("Something the program changed itself is forgotten at once")
    @MainActor
    func forgottenOnDemand() {
        var asks = 0
        func ask() -> Int { ThisTurn.answer("test.forgotten") { asks += 1; return asks } }

        #expect(ask() == 1)
        ThisTurn.forget()
        #expect(ask() == 2)
    }

    @Test("Two questions in one turn keep their own answers")
    @MainActor
    func answersAreNotSharedBetweenQuestions() {
        ThisTurn.forget()
        #expect(ThisTurn.answer("test.one") { "one" } == "one")
        #expect(ThisTurn.answer("test.two") { "two" } == "two")
        #expect(ThisTurn.answer("test.one") { "changed" } == "one")
    }

    /// Off the main thread there is no dictionary to read: the memo is guarded
    /// by the main thread rather than by a lock, and a background caller gets
    /// the machine's own answer every time.
    @Test("A background caller is never answered from the memo")
    func backgroundCallersAlwaysAsk() async {
        let asks = await Task.detached { () -> Int in
            var asks = 0
            for _ in 0..<3 { _ = ThisTurn.answer("test.background") { asks += 1 } }
            return asks
        }.value
        #expect(asks == 3)
    }
}
