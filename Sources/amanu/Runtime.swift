import AppKit
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

    // MARK: - being asked for, rather than asking on someone else's behalf

    /// Set on the copy we hand over to, so a launch this program cannot read
    /// correctly can cost at most one extra start rather than an endless
    /// sequence of them.
    static let handOffMarker = "AMANU_OPENED_BY_AMANU"

    /// Whether LaunchServices started this process — which is the same
    /// question as whether TCC will hold *this* program responsible for what
    /// it asks for.
    ///
    /// The parent process id looks like the obvious test and is the wrong
    /// one. Measured on 19 August 2026 with a signed bundle that had no TCC
    /// record of its own, reading its own calendar authorization three ways:
    ///
    ///   | started by                | ppid | XPC_SERVICE_NAME | status |
    ///   | shell                     | shell| 0                | full   |
    ///   | shell, double-forked      | 1    | 0                | full   |
    ///   | LaunchServices            | 1    | application.…    | none   |
    ///
    /// "full" is the terminal's grant being read by a program that was never
    /// granted anything: both shell launches are answered against the
    /// responsible process, and reparenting to launchd does not change that.
    /// Only the LaunchServices launch is answered against the bundle itself.
    static func startedThroughLaunchServices(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XPC_SERVICE_NAME"]?.hasPrefix("application.") ?? false
    }

    /// Whether this invocation should open the bundle and step aside instead
    /// of becoming the app itself.
    ///
    /// A bare build has nothing to hand over to and answers false: `swift run`
    /// and the tests are the shell's responsibility by their nature, and that
    /// is the bargain a bare build already makes everywhere else.
    static func shouldHandOffToBundle(
        bundle: Bundle?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard bundle != nil, environment[handOffMarker] == nil else { return false }
        return !startedThroughLaunchServices(environment: environment)
    }

    /// Ask LaunchServices to start the bundle, so the copy that shows the
    /// window and asks for the permissions is answering for itself.
    @MainActor
    static func handOffToBundle(_ bundle: Bundle, arguments: [String] = []) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        // Whatever was typed still has to be honoured — a `--out` that only
        // the terminal copy obeys would send the recordings somewhere the app
        // never looks.
        configuration.arguments = arguments
        // Never a second recorder beside the first: `handOverToRunningCopy`
        // has already looked, and if one appeared in the meantime the right
        // answer is still to bring that one forward.
        configuration.createsNewApplicationInstance = false
        configuration.activates = true
        configuration.environment = [handOffMarker: "1"]

        final class Answer: @unchecked Sendable {
            var launched = false
        }
        let answer = Answer()
        let finished = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: configuration) {
            app, _ in
            answer.launched = app != nil
            finished.signal()
        }
        // The completion arrives off the main thread, so waiting here is safe;
        // the timeout is only so a wedged LaunchServices cannot hang a command
        // someone typed.
        guard finished.wait(timeout: .now() + 20) == .success else { return false }
        return answer.launched
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
