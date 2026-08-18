import Foundation
import Network

/// Tells the program when the machine goes from offline to online.
///
/// Post-processing defers rather than fails when there is no network, which is
/// only half an answer: something has to notice when the network comes back.
/// Without this the backlog waits for the next launch, and a laptop that lives
/// in sleep-and-wake for weeks may not have one for weeks — the meeting
/// recorded on a train would still be nameless in the office that afternoon.
///
/// Only the offline → online edge is reported. Going offline needs no action,
/// and `NWPathMonitor` reports plenty of transitions that aren't either
/// (interface changes, a VPN attaching), which would otherwise fire a sweep
/// every time somebody walks past a wifi boundary.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.samat.amanu.network")
    private var wasSatisfied: Bool?
    private let onReturn: @Sendable () -> Void

    init(onReturn: @escaping @Sendable () -> Void) {
        self.onReturn = onReturn
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            defer { self.wasSatisfied = satisfied }
            // The first callback describes the world as it already was, not a
            // change to it: launch already sweeps, so treating it as an edge
            // would just run the same pass twice.
            guard let previous = self.wasSatisfied else { return }
            if satisfied, !previous { self.onReturn() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
