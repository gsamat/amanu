import Foundation

/// One answer from the machine, remembered until the main run loop turns.
///
/// Asking macOS what it has granted is not free: a TCC lookup is milliseconds
/// and `SMAppService.mainApp.status` is an XPC round trip to another daemon —
/// 14 ms of one, measured inside the signed bundle on 19 August 2026. The
/// setup form asks the same three questions a dozen times to draw itself once:
/// the access rows ask, the highlight asks again to find the row to tint, and
/// the footer asks twice more to say what is left and what its button should
/// say. Picking a summary card spent a quarter of a second on that and nothing
/// else, which is long enough to feel like the click was missed.
///
/// A turn of the run loop is one instant as far as a person is concerned:
/// nothing they did in it can have changed a grant, since granting one means
/// going to System Settings and coming back. So the first ask goes out to the
/// system and the rest of the turn reads the answer it brought back, and the
/// next event asks again — which is the freshness the form had before, without
/// the repetition.
enum ThisTurn {
    private nonisolated(unsafe) static var answers: [String: Any] = [:]
    private nonisolated(unsafe) static var forgetting = false

    /// The answer to `question`, asked at most once per turn.
    ///
    /// Off the main thread nothing is remembered: the dictionary is guarded by
    /// the main thread rather than by a lock, and a background caller — the
    /// doctor's checks, a watcher — is not the one asking twelve times.
    static func answer<Value>(_ question: String, _ ask: () -> Value) -> Value {
        guard Thread.isMainThread else { return ask() }
        if let known = answers[question] as? Value { return known }
        let answer = ask()
        answers[question] = answer
        if !forgetting {
            forgetting = true
            DispatchQueue.main.async {
                answers = [:]
                forgetting = false
            }
        }
        return answer
    }

    /// Forget now, for the one case the run loop cannot cover: something this
    /// program did — registering a login item, granting itself something —
    /// that changes an answer inside the turn that reads it again.
    static func forget() {
        guard Thread.isMainThread else { return }
        answers = [:]
    }
}
