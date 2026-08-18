import Foundation
import ServiceManagement

/// Start at login, for the application bundle.
///
/// The bare binary had to ship its own LaunchAgent plist, because system audio
/// is only captured by the copy launchd owns (.issues/rca-002) and a plist was
/// the only way to be that copy. A signed bundle is its own responsible
/// process — the spike in `spike/tcc-bundle` measured it — so the plist is no
/// longer buying anything, and `SMAppService.mainApp` is what macOS shows in
/// Login Items, where someone would look for it.
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

    static func status() -> State {
        guard Runtime.isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    @discardableResult
    static func register() throws -> State {
        guard Runtime.isBundled else { return .unavailable }
        try SMAppService.mainApp.register()
        return status()
    }

    @discardableResult
    static func unregister() throws -> State {
        guard Runtime.isBundled else { return .unavailable }
        try SMAppService.mainApp.unregister()
        return status()
    }

    /// The Login Items pane, for the case macOS wants a human to say yes.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
