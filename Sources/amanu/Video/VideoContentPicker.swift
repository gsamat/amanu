import AppKit
import ScreenCaptureKit

/// The system content-sharing picker, wired to amanu's video start.
///
/// The automatic window choice gets the meeting wrong too often to be the
/// only way in — a call app has a launcher, a meeting window, a toolbar and
/// a chat panel, all in one family, and no heuristic outside Apple can say
/// which of them the person means. The picker is macOS's own answer to that
/// question: the same UI screen sharing uses, with thumbnails, one click,
/// and a menu for changing the selection later. Available since macOS 14,
/// so it covers everything above the floor.
///
/// The user's selection arrives as a finished `SCContentFilter` in
/// `onSelection`; later changes (the picker stays available while
/// `allowsChangingSelectedContent` is on) arrive the same way, and it is the
/// caller's job to apply them to the running stream.
@MainActor
final class VideoContentPicker: NSObject, SCContentSharingPickerObserver {
    /// The user picked content (a window, an application, or a display).
    var onSelection: (@MainActor (SCContentFilter) -> Void)?
    /// The picker was dismissed without choosing anything.
    var onCancel: (@MainActor () -> Void)?
    /// The picker itself failed to start — shown, then treated like a cancel.
    var onStartFailed: (@MainActor (Error) -> Void)?

    private var observing = false

    /// Configure and show the picker. Own windows are excluded — recording
    /// amanu is recording the person watching amanu — and the user may
    /// change their selection later, which arrives here as another
    /// `onSelection`.
    func present() {
        let picker = SCContentSharingPicker.shared
        if !observing {
            picker.add(self)
            observing = true
        }

        var configuration = picker.defaultConfiguration
        configuration.allowedPickerModes = [
            .singleWindow, .singleApplication, .singleDisplay,
        ]
        configuration.allowsChangingSelectedContent = true
        if let ownBundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [ownBundleID]
        }
        picker.defaultConfiguration = configuration

        // Without this the present call is a polite no-op: the UI appears
        // only for a picker the app has marked as in use.
        picker.isActive = true
        picker.present()
    }

    /// Detach from the picker — when video stops, the system's change UI
    /// should stop offering to re-point a stream that no longer exists.
    func dismiss() {
        SCContentSharingPicker.shared.remove(self)
        observing = false
    }

    /// The system video menu and the green capture indicator follow this
    /// flag: when no stream is running it must be off, or macOS keeps
    /// showing amanu as if it were still recording the screen.
    static func setActive(_ active: Bool) {
        SCContentSharingPicker.shared.isActive = active
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.observing = false
            self.onCancel?()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        nonisolated(unsafe) let chosen = filter
        Task { @MainActor in
            self.onSelection?(chosen)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.onStartFailed?(error)
            SCContentSharingPicker.shared.remove(self)
            self.observing = false
        }
    }
}
