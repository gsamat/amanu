import Foundation

/// What amanu asks of the power manager, kept in one place because the sets
/// differ by a single bit and their names do not show it. `.userInitiated`
/// includes `.idleSystemSleepDisabled`: held for the life of the app, it kept
/// the Mac from idle-sleeping for as long as amanu ran. The variant that
/// allows idle system sleep keeps App Nap away just as well, so that is what
/// amanu holds while it waits. Sleep is held off only while there is a meeting to keep — being
/// recorded, or being transcribed.
enum Wakefulness {
    static let lifetime: ProcessInfo.ActivityOptions = [
        .userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled,
        .automaticTerminationDisabled,
    ]

    static let recording: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]

    /// Somebody who walks away after a call should come back to a transcript,
    /// not to a queue that stopped when the Mac went to sleep.
    static let transcribing = recording

    typealias Hold = @Sendable (_ reason: String) -> () -> Void

    /// A closure that ends the activity, rather than the activity itself, so a
    /// test can count holds without asking the power manager.
    static let holdAwake: Hold = { reason in
        let activity = ProcessInfo.processInfo.beginActivity(
            options: Wakefulness.transcribing, reason: reason)
        return { ProcessInfo.processInfo.endActivity(activity) }
    }
}
