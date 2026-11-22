import Foundation
import Testing

@testable import amanu

// The child's deadline begins after launch. A wall-clock stopwatch around
// the async call also measures dispatch-queue and test-executor scheduling;
// the shared CI runner can spend several seconds there before the child runs.
// Assert the timeout/cancellation outcome, with a separate runaway-test limit.
@Suite(.timeLimit(.minutes(1)))
struct SubprocessTests {
    @Test("A GUI-installed Codex launcher can find its interpreter for both probing and summaries")
    func codexLauncherPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = directory.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = bin.appendingPathComponent("codex")
        let interpreter = bin.appendingPathComponent("amanu-test-node")
        try "#!/usr/bin/env amanu-test-node\n".write(to: codex, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nif [ \"$2\" = --version ]; then printf 'codex test version'; else /bin/cat; fi\n"
            .write(to: interpreter, atomically: true, encoding: .utf8)
        for executable in [codex, interpreter] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let home = Home(url: directory, environment: ["PATH": "/usr/bin:/bin", "SHELL": "/usr/bin/false"],
                        discoversTools: true, languageModels: nil)
        try await Home.$scoped.withValue(home) {
            Tooling.forget()
            defer { Tooling.forget() }
            #expect(Tooling.probe("codex")?.path == codex.path)
            #expect(Tooling.probe("codex")?.version == "codex test version")
            let result = try await LLMBackend.run(executable: codex.path, arguments: ["exec"],
                                                  input: "meeting prompt", timeout: 2)
            #expect(result == "meeting prompt")
        }
    }

    @Test("Explicit child environment is isolated from inherited process variables")
    func childEnvironment() async throws {
        let result = try await Subprocess.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"${AMANU_TEST_ONLY-}\" \"${PATH-}\""],
            input: Data(), timeout: 2,
            environment: ["AMANU_TEST_ONLY": "child", "PATH": "/usr/bin:/bin"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "child:/usr/bin:/bin")
    }

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
