import AppKit
import Foundation

/// Redraw when the config file changes, whoever changed it.
///
/// Two windows now show the same form — setup is also the first tab of
/// settings — and both windows write the same file. A person who changed the
/// transcription provider in one and looked at the other saw the old answer
/// until the window was reopened: the file was right and the picture was
/// wrong, which is the worst way for a setting to fail, because it reads as
/// the change not having been saved.
///
/// So no window is told about any other. Each says what it renders, listens
/// for the file changing, and reads it again — the same thing it does when it
/// is reopened, which is the code path that was already trusted.
@MainActor
enum ConfigWatch {
    /// Call `redraw` after every successful write to the config file. Keep
    /// the returned token for as long as the redrawing is wanted; dropping it
    /// stops the observation.
    static func observe(_ redraw: @escaping @MainActor () -> Void) -> Token {
        Token(NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: nil
        ) { _ in
            // Delivered on whichever thread wrote — which today is always the
            // main one, since every writer is a control somebody clicked. The
            // check is here because "today" is not a guarantee, and AppKit
            // from a background thread is a crash rather than a glitch.
            if Thread.isMainThread {
                MainActor.assumeIsolated { redraw() }
            } else {
                DispatchQueue.main.async { redraw() }
            }
        })
    }

    /// Keeps one observation alive, and ends it when it goes.
    final class Token {
        private let observer: NSObjectProtocol

        init(_ observer: NSObjectProtocol) { self.observer = observer }

        deinit { NotificationCenter.default.removeObserver(observer) }
    }
}
