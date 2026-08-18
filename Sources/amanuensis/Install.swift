import ArgumentParser
import Foundation

/// Manage amanuensis's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since amanuensis ships as a single binary, a plain LaunchAgent
/// plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register amanuensis to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    static let label = "me.samat.amanuensis"

    /// Where the LaunchAgent lives. Shared with `amanuensis doctor`, which reports
    /// whether it's installed — without it, system audio records silence
    /// (rca-002).
    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private var plistURL: URL { Self.agentPlistURL }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/amanuensis.out.log",
            "StandardErrorPath": "/tmp/amanuensis.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   /tmp/amanuensis.out.log, /tmp/amanuensis.err.log")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    /// The agent points at whichever binary you ran `amanuensis install` from —
    /// there's no canonical install path to assume, and there shouldn't be
    /// (`~/.local/bin` needs no sudo; `/usr/local/bin` doesn't exist on a
    /// stock Mac).
    ///
    /// Asking dyld beats trusting argv[0]: a shell invoking amanuensis off PATH
    /// usually passes an absolute path, but nothing guarantees it, and the
    /// consequence of getting it wrong is an agent that silently never starts.
    /// Symlinks are resolved so TCC sees the same path the daemon runs from.
    private func resolveBinaryPath() throws -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            FileHandle.standardError.write(Data(
                "couldn't locate the running amanuensis binary\n".utf8
            ))
            throw ExitCode(1)
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            FileHandle.standardError.write(Data(
                "resolved binary path is not executable: \(path)\n".utf8
            ))
            throw ExitCode(1)
        }
        return path
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
