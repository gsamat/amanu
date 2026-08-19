import AppKit
import ArgumentParser
import Foundation

/// Open the setup window in the running daemon. If there is no daemon to ask,
/// this invocation becomes the app and shows the window itself.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the permissions and transcription setup window."
    )

    func run() throws {
        SetupState.reset()

        let reachedRunningApp = MainActor.assumeIsolated {
            SetupRequest.askRunningApp()
        }
        if reachedRunningApp { return }

        // No live app answered, so this process becomes the app. That matters:
        // TCC grants belong to the signed process that asks for them, and the
        // window asks for system audio.
        //
        // Built through `parse` rather than by calling the initializer:
        // `Run` carries an `@Option`, and a command constructed without
        // parsing has no value behind that property — reading it traps with
        // "Can't read a value from a parsable argument definition". Which is
        // what `amanu setup` did on the one machine that needs this branch:
        // a fresh install nobody has launched yet.
        try Run.parse([]).run()
    }
}

/// A small cross-process doorbell for `amanu setup`. Distributed notifications
/// are local to this Mac and let the CLI reuse the existing daemon instead of
/// starting a second recorder beside it.
enum SetupRequest {
    private static let show = Notification.Name("me.samat.amanu.show-setup")
    private static let acknowledged = Notification.Name("me.samat.amanu.show-setup-ack")

    @MainActor
    private final class Reply {
        var arrived = false
    }

    @MainActor
    static func askRunningApp(timeout: TimeInterval = 4) -> Bool {
        let center = DistributedNotificationCenter.default()
        let requestID = UUID().uuidString
        let reply = Reply()
        let token = center.addObserver(
            forName: acknowledged, object: requestID, queue: .main
        ) { _ in
            MainActor.assumeIsolated { reply.arrived = true }
        }
        defer { center.removeObserver(token) }

        center.postNotificationName(show, object: requestID, deliverImmediately: true)

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
    static func observe(_ action: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: show, object: nil, queue: .main) { note in
            // Extract the Sendable value before crossing into MainActor;
            // carrying Foundation's whole Notification across is a Swift 6
            // data-race error even though this observer is delivered on main.
            let requestID = note.object as? String
            MainActor.assumeIsolated {
                // Acknowledge first: opening the window can take longer than
                // the caller is willing to wait, and being slow is not the
                // same as being absent.
                center.postNotificationName(
                    acknowledged,
                    object: requestID,
                    deliverImmediately: true
                )
                action()
            }
        }
    }
}
