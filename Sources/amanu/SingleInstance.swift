import AppKit
import Foundation

/// One recorder per Mac.
///
/// A second copy is not a harmless duplicate: both would hold the microphone,
/// both would notice the same call app, and the meeting would end up as two
/// half-recordings in two folders. Opening an app that is already open is an
/// ordinary thing for a person to do — from the Dock, from Spotlight, by
/// double-clicking it in /Applications — so the second copy asks the first to
/// come forward and then gets out of the way.
enum SingleInstance {
    private static let ping = Notification.Name("me.samat.amanu.activate")
    private static let pong = Notification.Name("me.samat.amanu.activate-ack")

    @MainActor
    private final class Reply {
        var arrived = false
    }

    /// Ask whoever is already running to show themselves. True when someone
    /// answered, which means this process should quietly stop.
    @MainActor
    static func handOverToRunningCopy(timeout: TimeInterval = 4) -> Bool {
        let center = DistributedNotificationCenter.default()
        let requestID = UUID().uuidString
        let reply = Reply()
        let token = center.addObserver(forName: pong, object: requestID, queue: .main) { _ in
            MainActor.assumeIsolated { reply.arrived = true }
        }
        defer { center.removeObserver(token) }

        center.postNotificationName(ping, object: requestID, deliverImmediately: true)

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
    static func observe(_ activate: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: ping, object: nil, queue: .main) { note in
            let requestID = note.object as? String
            MainActor.assumeIsolated {
                // Answer first: a second copy is sitting in a one-second wait,
                // and bringing a window forward can take longer than that.
                center.postNotificationName(pong, object: requestID, deliverImmediately: true)
                NSApp.activate(ignoringOtherApps: true)
                activate()
            }
        }
    }
}
