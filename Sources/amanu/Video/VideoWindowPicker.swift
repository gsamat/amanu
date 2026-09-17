import CoreGraphics
import Foundation

/// One capturable window, as plain data: everything choosing a video target
/// needs, none of the ScreenCaptureKit objects a test cannot build without a
/// Screen Recording grant on the test machine.
struct VideoWindowCandidate {
    let windowID: CGWindowID
    /// Bundle id of the owning application, nil for windows owned by a
    /// process that has none.
    let owningBundleID: String?
    let isOnScreen: Bool
    let frame: CGRect
    let layer: Int
    /// The active window of its own application — the meeting window, once
    /// the meeting exists, and not the launcher that opened before it.
    var isActive: Bool = false
}

/// One capturable display, likewise plain data.
struct VideoDisplayCandidate {
    let displayID: CGDirectDisplayID
}

/// Where the video stream is pointed once capture begins.
enum VideoCaptureTarget: Equatable {
    /// A window belonging to the call app.
    case window(id: CGWindowID, bundleID: String)
    /// The whole main display — when the call app's window cannot be picked
    /// out, or when capture is asked for the display outright.
    case display(id: CGDirectDisplayID)
}

enum VideoCaptureMode: Equatable {
    case window
    case display

    /// From config. An unrecognised value defaults to window capture (the default);
    /// "display" selects the full display.
    static func from(_ value: String?) -> VideoCaptureMode {
        value == "display" ? .display : .window
    }

    /// The word meta.json records under `video_capture`.
    var label: String {
        switch self {
        case .window: return "window"
        case .display: return "display"
        }
    }
}

/// Which window the video track records. The same family rule the system-audio
/// tap follows decides what counts as the call app, so the two tracks stay
/// pointed at the same call.
enum VideoWindowPicker {
    /// Pick the meeting window: the largest on-screen window owned by one of
    /// the call-app families, falling back to the main display when none can
    /// be identified. Nil only when there is no display either — the stream
    /// has nothing at all to point at, and starting a session that will write
    /// no frames is worse than failing it.
    static func choose(
        windows: [VideoWindowCandidate],
        displays: [VideoDisplayCandidate],
        families: [String],
        mode: VideoCaptureMode
    ) -> VideoCaptureTarget? {
        guard let display = displays.first else { return nil }
        guard mode == .window, !families.isEmpty else {
            return .display(id: display.displayID)
        }

        // Helper processes count, because the process that draws a call's
        // video is rarely the bundle you'd name — the same reason the tap
        // matches prefixes. Off-screen, zero-area and non-normal-layer
        // windows do not, or every overlay a call app draws would be one.
        let owned = windows.filter { window in
            window.isOnScreen
                && window.layer == 0
                && window.frame.width > 1 && window.frame.height > 1
                && belongsToFamily(window, families)
        }
        guard var window = owned.first else {
            return .display(id: display.displayID)
        }
        // Reduce rather than max(by:): `preference` reads "a deserves it
        // more", and handing a "greater" predicate to `max(by:)` would
        // quietly pick the least deserving window.
        for candidate in owned.dropFirst() where preference(candidate, window) {
            window = candidate
        }
        return .window(id: window.windowID, bundleID: window.owningBundleID ?? "")
    }

    /// The family rule lives in AudioProcesses — bundle-id prefix, executable
    /// name when there is no bundle id — because two rules that drift apart
    /// would put the video and the far-end track on different calls. A window
    /// with no bundle id is never the meeting window.
    private static func belongsToFamily(
        _ window: VideoWindowCandidate, _ families: [String]
    ) -> Bool {
        guard let bundleID = window.owningBundleID, !bundleID.isEmpty else { return false }
        return AudioProcesses.belongs(
            AudioProcesses.Process(
                object: 0, pid: 0, bundleID: bundleID,
                name: bundleID, runningInput: false, runningOutput: false
            ),
            to: families
        )
    }

    /// Which of two windows deserves the recording more. Activity first:
    /// the app's own active window is the meeting once the meeting exists,
    /// and the launcher that opened before it is not — a launcher bigger
    /// than the meeting window used to win on size alone and record the
    /// wrong half of the call. Area second; the id breaks ties so the
    /// choice never oscillates between two identical windows.
    static func preference(_ a: VideoWindowCandidate, _ b: VideoWindowCandidate) -> Bool {
        if a.isActive != b.isActive { return a.isActive }
        let areaA = a.frame.width * a.frame.height
        let areaB = b.frame.width * b.frame.height
        if areaA != areaB { return areaA > areaB }
        return a.windowID < b.windowID
    }
}
