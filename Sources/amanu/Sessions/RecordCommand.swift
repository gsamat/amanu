import AppKit
import ArgumentParser
import Foundation

/// Start or stop a recording in the amanu that is already running.
///
/// It never records anything itself. System audio is granted to the
/// application, and a second recorder launched from a terminal captures
/// digital silence (see `.issues/rca-002`) — so this asks the running app and
/// says so plainly when nobody answers.
struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start or stop recording in the running amanu."
    )

    @Argument(help: "start, stop, or toggle.")
    var action: RecordRequest.Action

    func run() throws {
        let answered = MainActor.assumeIsolated { RecordRequest.askRunningApp(action) }
        guard answered else {
            throw CleanExit.message(
                "amanu isn't running. Start it from the Dock, or `launchctl kickstart "
                    + "gui/$(id -u)/me.samat.amanu`.")
        }
    }
}

/// The same cross-process doorbell `amanu setup` uses, carrying which of the
/// three verbs was asked for. Distributed notifications never leave this Mac.
enum RecordRequest {
    enum Action: String, ExpressibleByArgument, Sendable {
        case start
        case stop
        case toggle
    }

    private static let request = Notification.Name("me.samat.amanu.record")
    private static let acknowledged = Notification.Name("me.samat.amanu.record-ack")

    @MainActor
    private final class Reply {
        var arrived = false
    }

    /// The request identifier and the verb travel together in the notification
    /// object, because that is the only field a distributed notification can
    /// carry between two processes that share no user info.
    private static func encode(_ id: String, _ action: Action) -> String {
        "\(id) \(action.rawValue)"
    }

    private static func decode(_ object: String?) -> (id: String, action: Action)? {
        guard let parts = object?.split(separator: " ", maxSplits: 1), parts.count == 2,
              let action = Action(rawValue: String(parts[1]))
        else { return nil }
        return (String(parts[0]), action)
    }

    @MainActor
    static func askRunningApp(_ action: Action, timeout: TimeInterval = 4) -> Bool {
        let center = DistributedNotificationCenter.default()
        let requestID = UUID().uuidString
        let reply = Reply()
        let token = center.addObserver(
            forName: acknowledged, object: requestID, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reply.arrived = true }
        }
        defer { center.removeObserver(token) }

        center.postNotificationName(
            request, object: encode(requestID, action), deliverImmediately: true)

        let deadline = Date().addingTimeInterval(timeout)
        while !reply.arrived, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }
        return reply.arrived
    }

    @MainActor
    static func observe(_ act: @escaping @MainActor (Action) -> Void) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: request, object: nil, queue: .main) { note in
            // Pull the Sendable string out before crossing into MainActor:
            // carrying the whole Notification across is a data race to Swift 6,
            // even though this observer is delivered on main.
            let object = note.object as? String
            MainActor.assumeIsolated {
                guard let (requestID, action) = decode(object) else { return }
                // Answer before acting. Starting a recording takes a moment —
                // the tap, the file, the engine — and a caller that waits for
                // the work to finish before hearing anything concludes that
                // nobody is home and says so, having just been obeyed.
                center.postNotificationName(
                    acknowledged, object: requestID, deliverImmediately: true)
                act(action)
            }
        }
    }
}
