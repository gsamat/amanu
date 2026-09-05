import ArgumentParser
import Foundation

/// `amanu analytics` — what is being sent, and the switch.
///
/// The identifier is printed because it is the only way somebody can ask for
/// their own data to be removed: it is the whole of what the server knows
/// them by, and nobody can be expected to guess a UUID they never saw.
struct AnalyticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analytics",
        abstract: "Show or change what amanu reports about how it is used."
    )

    @Argument(help: "`on` or `off`. Omit to print the current state.")
    var state: String?

    func run() throws {
        if let state {
            switch state.lowercased() {
            case "on":
                // Cleared rather than written: the default is on, and a config
                // file that only holds what you changed keeps reading as a
                // list of decisions.
                Config.update(path: ["analytics"], value: nil)
            case "off":
                Config.update(path: ["analytics"], value: false)
                try? FileManager.default.removeItem(at: AnalyticsSink.defaultStore)
            default:
                throw ValidationError("say `on` or `off`.")
            }
        }

        let on = AnalyticsIdentity.isEnabled()
        // Started before the identifier is printed, because printing it makes
        // the file, and the missing file is what `installed` is waiting for —
        // asking a question about analytics should not silently answer it.
        if on { Analytics.start(surface: .cli) }
        defer { if on { Analytics.flushOnExit() } }

        print(on ? "analytics: on" : "analytics: off")
        if on {
            print("identifier: \(AnalyticsIdentity.identifier())")
            print("sent to:    \(AnalyticsSink.Endpoint.url.absoluteString)")
        }
        print("")
        print("Every event and property is listed in docs/analytics.md.")
        print("Recordings, transcripts, summaries and their names are never sent,")
        print("and no address is stored at the other end.")
        if on {
            print("")
            print("To be forgotten there, quote the identifier above.")
            print("To forget it here:  rm ~/.config/amanu/analytics*.json")
        }
    }
}
