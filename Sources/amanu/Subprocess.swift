import Darwin
import Foundation

/// Bounded CLI execution. Unlinked, owner-only temporary files avoid pipe
/// backpressure while keeping prompts and responses out of directory listings.
enum Subprocess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum Failure: Error { case outputTooLarge }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    static func run(executable: String, arguments: [String], input: Data,
                    timeout: TimeInterval) async throws -> Output {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try runSync(
                            executable: executable, arguments: arguments, input: input,
                            timeout: timeout, isCancelled: { cancellation.isCancelled }))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    static func runSync(executable: String, arguments: [String], input: Data = Data(),
                        timeout: TimeInterval,
                        isCancelled: @Sendable () -> Bool = { false }) throws -> Output {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        func anonymousFile(_ name: String) throws -> FileHandle {
            let path = scratch.appendingPathComponent(name).path
            let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard unlink(path) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? handle.close()
                throw error
            }
            return handle
        }
        let stdin = try anonymousFile("stdin")
        defer { try? stdin.close() }
        let stdout = try anonymousFile("stdout")
        defer { try? stdout.close() }
        let stderr = try anonymousFile("stderr")
        defer { try? stderr.close() }
        try stdin.write(contentsOf: input)
        try stdin.seek(toOffset: 0)
        if isCancelled() { throw CancellationError() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            if done.wait(timeout: .now() + 0.25) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        func size(_ handle: FileHandle) -> Int64 {
            var info = stat()
            return fstat(handle.fileDescriptor, &info) == 0 ? Int64(info.st_size) : 0
        }
        while done.wait(timeout: .now() + 0.02) == .timedOut {
            if isCancelled() { stop(); throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop()
                throw URLError(.timedOut)
            }
            if size(stdout) + size(stderr) > 32 * 1024 * 1024 {
                stop()
                throw Failure.outputTooLarge
            }
        }
        if isCancelled() { throw CancellationError() }
        guard size(stdout) + size(stderr) <= 32 * 1024 * 1024 else {
            throw Failure.outputTooLarge
        }
        try stdout.seek(toOffset: 0)
        try stderr.seek(toOffset: 0)
        return Output(status: process.terminationStatus,
                      stdout: try stdout.readToEnd() ?? Data(),
                      stderr: try stderr.readToEnd() ?? Data())
    }
}
