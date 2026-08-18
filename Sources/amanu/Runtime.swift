import Foundation

/// How this copy of amanu is running: as `Amanu.app`, or as the bare binary
/// it used to be.
///
/// The difference decides real behaviour, not cosmetics. A bundle can register
/// itself with `SMAppService.mainApp`, post notifications under its own name,
/// and — as the TCC spike measured — be its own responsible process for system
/// audio. A bare build — `swift run`, a test — can do none of those, so the
/// few places that depend on it ask here rather than assuming.
enum Runtime {
    /// The application bundle this process lives in, or nil when it is a bare
    /// executable. `Bundle.main` answers for both, so the question is asked of
    /// the path rather than of the identifier — a binary with an embedded
    /// Info.plist has an identifier too.
    static var appBundle: Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }

        // `~/.local/bin/amanu` is a symlink into the bundle, and Foundation
        // answers for the path it was invoked through — which is a plain
        // directory. Follow the link before deciding: the CLI running out of
        // the bundle is the same program as the app, and registering a login
        // item depends on knowing that.
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let bundleURL = executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Amanu.app
        guard bundleURL.pathExtension == "app" else { return nil }
        return Bundle(url: bundleURL)
    }

    static var isBundled: Bool { appBundle != nil }

    static var bundleURL: URL? { appBundle?.bundleURL }

    /// The executable to point the command-line symlink at.
    static var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
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
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if argument.hasPrefix("-psn_") { continue }
            // These come in pairs — `-NSDocumentRevisionsDebugMode YES` — and
            // dropping the flag while keeping its value leaves the value
            // looking like a subcommand.
            if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                if index < arguments.endIndex, !arguments[index].hasPrefix("-") { index += 1 }
                continue
            }
            kept.append(argument)
        }
        return kept
    }
}
