import Foundation

/// How this copy of amanu is running: as `Amanu.app`, or as the bare binary
/// it used to be.
///
/// The difference decides real behaviour, not cosmetics. A bundle can register
/// itself with `SMAppService.mainApp`, post notifications under its own name,
/// and — as the TCC spike measured — be its own responsible process for system
/// audio. The bare binary can do none of those and needs the LaunchAgent
/// instead, which is why both paths are kept while the migration runs.
enum Runtime {
    /// The application bundle this process lives in, or nil when it is a bare
    /// executable. `Bundle.main` answers for both, so the question is asked of
    /// the path rather than of the identifier — a binary with an embedded
    /// Info.plist has an identifier too.
    static var appBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        return Bundle.main
    }

    static var isBundled: Bool { appBundle != nil }

    static var bundleURL: URL? { appBundle?.bundleURL }

    /// The executable to point a symlink or a launchd job at.
    static var executableURL: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// Where a released copy is expected to live. An app run from the Downloads
    /// folder or from a mounted disk image works, but updating and login items
    /// only make sense once it has been moved.
    static var isInApplications: Bool {
        guard let bundleURL else { return false }
        return bundleURL.deletingLastPathComponent().path.hasSuffix("/Applications")
    }

    /// LaunchServices hands an app arguments of its own on some launches, and
    /// ArgumentParser rightly refuses to understand them. They are noise from
    /// the window server, never a command someone typed.
    static func meaningfulArguments(_ arguments: [String]) -> [String] {
        arguments.filter { argument in
            !argument.hasPrefix("-psn_")
                && !argument.hasPrefix("-NS")
                && !argument.hasPrefix("-Apple")
        }
    }
}
