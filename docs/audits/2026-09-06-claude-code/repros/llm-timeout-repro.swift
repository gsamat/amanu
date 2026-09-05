// Original LLMBackend.run copied verbatim except private visibility; synthetic LLMError stub.
import Foundation
struct LLMBackend {
    static func run(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        // `claude` and `codex` are agents: they read the directory they are
        // started in and go looking for context. Started wherever the daemon
        // happens to stand, they earn privacy prompts that macOS bills to
        // amanu, which is the process that launched them. An empty directory
        // of their own leaves nothing to find — the whole conversation goes
        // over stdin anyway.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-llm-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        task.currentDirectoryURL = scratch

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        // Write and close before reading: the child blocks on EOF, we'd block
        // on its output, and neither would move.
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw LLMError.exit(
                Int(task.terminationStatus),
                String(decoding: err.prefix(600), as: UTF8.self)
                    + String(decoding: out.suffix(600), as: UTF8.self)
            )
        }
        return String(decoding: out, as: UTF8.self)
    }
}
enum LLMError: Error { case exit(Int, String) }
@main struct Repro {
    static func main() async throws {
        _ = try await LLMBackend.run(executable: "/bin/sleep", arguments: ["15"], input: String(repeating: "x", count: 1024 * 1024), timeout: 0.2)
    }
}
