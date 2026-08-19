import Foundation
import ServiceManagement

/// Start at login, for the application bundle.
///
/// A signed bundle is its own responsible process for system audio — the
/// spike in `spike/tcc-bundle` measured it — so amanu registers itself the way
/// every other application does, and appears in Login Items where someone
/// would look for it.
enum LoginItem {
    enum State: Equatable {
        /// Registered, and macOS will start it at the next login.
        case enabled
        /// Not registered yet.
        case notRegistered
        /// Registered, but someone has to allow it in System Settings.
        case needsApproval
        /// This copy isn't an app bundle, so there is nothing to register.
        case unavailable
    }

    static var isAvailable: Bool { Runtime.isBundled }

    /// Asked of `ThisTurn` because `SMAppService.mainApp.status` is an XPC
    /// round trip, and the setup window asks this six times to draw itself
    /// once.
    static func status() -> State {
        ThisTurn.answer("login item") {
            guard Runtime.isBundled else { return State.unavailable }
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .needsApproval
            case .notRegistered, .notFound: return .notRegistered
            @unknown default: return .notRegistered
            }
        }
    }

    @discardableResult
    static func register() throws -> State {
        guard Runtime.isBundled else { return .unavailable }
        try SMAppService.mainApp.register()
        ThisTurn.forget()
        return status()
    }

    @discardableResult
    static func unregister() throws -> State {
        guard Runtime.isBundled else { return .unavailable }
        try SMAppService.mainApp.unregister()
        ThisTurn.forget()
        return status()
    }

    /// The Login Items pane, for the case macOS wants a human to say yes.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
