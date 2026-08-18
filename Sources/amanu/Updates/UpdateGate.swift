import Foundation

/// Whether an update may happen right now, asked without Sparkle in the room.
///
/// Sparkle's scheduler knows about days and versions; it does not know that
/// this particular program is holding two audio taps open and that quitting to
/// swap the binary would destroy the meeting someone is in. That is the whole
/// reason this type exists: the rule is amanu's, so it lives in amanu, where
/// it can be tested without a bundle, a framework, or a network.
///
/// `AppUpdates` is the thin adapter that asks these questions on Sparkle's
/// behalf.
@MainActor
final class UpdateGate {
    /// Which kind of check Sparkle is about to make. The distinction matters:
    /// a background check is the updater's idea and can always wait, while a
    /// check someone chose from a menu is a question that deserves an answer
    /// even mid-recording — answering it costs nothing, since installing is
    /// gated separately.
    enum Check {
        case userInitiated
        case background
        case informationOnly
    }

    private let isRecording: () -> Bool
    private var postponedInstall: (() -> Void)?

    init(isRecording: @escaping () -> Bool) {
        self.isRecording = isRecording
    }

    func mayCheck(_ check: Check) -> Bool {
        switch check {
        case .background:
            // Nothing good comes of discovering an update mid-meeting: the
            // download competes for the same network the far end is on, and
            // the only thing it can lead to is the offer to restart.
            return !isRecording()
        case .userInitiated, .informationOnly:
            return true
        }
    }

    /// Hold an installation back while a recording is running.
    ///
    /// Returns true when the install was postponed, in which case `install` is
    /// kept and run by `recordingDidFinish()`. Returns false when there is
    /// nothing to wait for and the caller should proceed immediately.
    func postponeInstallIfRecording(_ install: @escaping () -> Void) -> Bool {
        guard isRecording() else { return false }
        postponedInstall = install
        return true
    }

    /// The recording ended; anything held back may go ahead now.
    func recordingDidFinish() {
        guard let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }

    var hasPostponedInstall: Bool { postponedInstall != nil }
}
