import Foundation
import Testing

@testable import amanu

// The child's deadline begins after launch. A wall-clock stopwatch around
// the async call also measures dispatch-queue and test-executor scheduling;
// the shared CI runner can spend several seconds there before the child runs.
// Assert the timeout/cancellation outcome, with a separate runaway-test limit.
@Suite(.timeLimit(.minutes(1)))
struct SubprocessTests {
    @Test("Cancelling CLI processing stops waiting for the child")
    func cancellation() async throws {
        let task = Task {
            try await LLMBackend.run(executable: "/bin/sleep", arguments: ["10"],
                                     input: "", timeout: 20)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test("Large stdin and stderr do not block each other")
    func concurrentStreams() async throws {
        let input = String(repeating: "meeting transcript\n", count: 20_000)
        let output = try await LLMBackend.run(
            executable: "/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero >&2; cat"],
            input: input, timeout: 5)
        #expect(output == input)
    }

    @Test("A child that never consumes a large prompt reaches its deadline")
    func blockedInputTimesOut() async throws {
        do {
            _ = try await LLMBackend.run(
                executable: "/bin/sleep", arguments: ["10"],
                input: String(repeating: "x", count: 1_000_000), timeout: 0.1)
            Issue.record("Expected a deadline error")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
            #expect(LLMError.isTransient(error))
        }
    }

    @Test("A child that ignores SIGTERM is still bounded")
    func ignoresTermination() async throws {
        do {
            _ = try await LLMBackend.run(
                executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"],
                input: "", timeout: 0.2)
            Issue.record("Expected a deadline error")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test("Failed commands retain their exit status and diagnostic")
    func failedCommand() async throws {
        do {
            _ = try await LLMBackend.run(
                executable: "/bin/sh", arguments: ["-c", "printf 'failure' >&2; exit 7"],
                input: "", timeout: 2)
            Issue.record("Expected a command failure")
        } catch let LLMError.exit(code, message) {
            #expect(code == 7)
            #expect(message.contains("failure"))
        }
    }
}
