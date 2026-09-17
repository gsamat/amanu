import CoreGraphics
import Foundation
import Testing

@testable import amanu

/// Which window the video track points at. Asking ScreenCaptureKit needs a
/// Screen Recording grant; the rule that reads its answer does not, and the
/// rule is where the video ends up on the wrong call.
struct VideoWindowPickerTests {
    private func window(
        _ id: CGWindowID,
        bundle: String? = "us.zoom.xos",
        onScreen: Bool = true,
        width: CGFloat = 1280,
        height: CGFloat = 720,
        layer: Int = 0,
        active: Bool = false
    ) -> VideoWindowCandidate {
        VideoWindowCandidate(
            windowID: id,
            owningBundleID: bundle,
            isOnScreen: onScreen,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            layer: layer,
            isActive: active
        )
    }

    private let display = VideoDisplayCandidate(displayID: 1)

    @Test func aCallAppWindowBeatsTheDisplay() {
        let zoom = window(10)
        #expect(
            VideoWindowPicker.choose(
                windows: [zoom], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .window(id: 10, bundleID: "us.zoom.xos")
        )
    }

    /// The family rule is the tap's: prefix, not exact id, because the process
    /// drawing the call is often a helper.
    @Test func helperBundleIDsMatchByFamilyPrefix() {
        let helper = window(11, bundle: "com.microsoft.teams2.helper")
        #expect(
            VideoWindowPicker.choose(
                windows: [helper], displays: [display],
                families: ["com.microsoft.teams2"], mode: .window
            ) == .window(id: 11, bundleID: "com.microsoft.teams2.helper")
        )
    }

    /// Chrome renders Meet calls in a renderer process — a browser family
    /// catches the window the same way it catches the audio.
    @Test func aBrowserFamilyFindsTheTabWindow() {
        let chrome = window(12, bundle: "com.google.Chrome")
        #expect(
            VideoWindowPicker.choose(
                windows: [chrome], displays: [display],
                families: ["com.google.Chrome"], mode: .window
            ) == .window(id: 12, bundleID: "com.google.Chrome")
        )
    }

    @Test func theLargestWindowWins() {
        let small = window(20, width: 800, height: 600)
        let large = window(21, width: 1920, height: 1080)
        #expect(
            VideoWindowPicker.choose(
                windows: [small, large], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .window(id: 21, bundleID: "us.zoom.xos")
        )
    }

    /// Minimised windows are off-screen; a background call you can see nothing
    /// of is not worth a window either.
    @Test func offScreenWindowsAreSkipped() {
        let minimised = window(30, onScreen: false)
        #expect(
            VideoWindowPicker.choose(
                windows: [minimised], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .display(id: display.displayID)
        )
    }

    /// Every call app draws overlays — floating toolbars, reaction bursts —
    /// and most of them are tiny; layer 0 keeps a notification-sized window
    /// from being mistaken for the meeting.
    @Test func overlayLayersAndSpecksAreNotTheMeeting() {
        let overlay = window(40, width: 300, height: 80, layer: 25)
        let speck = window(41, width: 1, height: 1)
        #expect(
            VideoWindowPicker.choose(
                windows: [overlay, speck], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .display(id: display.displayID)
        )
    }

    /// A window whose owner has no bundle id — a bare process — can never be
    /// matched to a family, so it is not the meeting window either.
    @Test func aWindowWithNoBundleIDIsNotTheMeeting() {
        let mystery = window(50, bundle: nil)
        #expect(
            VideoWindowPicker.choose(
                windows: [mystery], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .display(id: display.displayID)
        )
    }

    /// No family match anywhere — a call amanu can't attribute. The display
    /// fallback keeps recording rather than pointing the stream at nothing,
    /// exactly as the audio tap falls back to everything.
    @Test func noFamilyMatchFallsBackToTheDisplay() {
        let finder = window(60, bundle: "com.apple.finder")
        #expect(
            VideoWindowPicker.choose(
                windows: [finder], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .display(id: display.displayID)
        )
    }

    @Test func askingForTheDisplaySkipsWindowPicking() {
        let zoom = window(70)
        #expect(
            VideoWindowPicker.choose(
                windows: [zoom], displays: [display],
                families: ["us.zoom"], mode: .display
            ) == .display(id: display.displayID)
        )
    }

    /// No families known (manual start with no call app detected) is display
    /// mode by construction — there is nothing to match a window against.
    @Test func noFamiliesKnownMeansTheDisplay() {
        let zoom = window(80)
        #expect(
            VideoWindowPicker.choose(
                windows: [zoom], displays: [display],
                families: [], mode: .window
            ) == .display(id: display.displayID)
        )
    }

    /// No display either — there is nothing to point at, and the session
    /// should hear about it rather than write a zero-frame file.
    @Test func withNoDisplayThereIsNothingToRecord() {
        #expect(
            VideoWindowPicker.choose(
                windows: [window(90)], displays: [],
                families: ["us.zoom"], mode: .window
            ) == nil
        )
    }

    /// Equal areas settle on the lower window id, so two same-sized windows
    /// cannot make the stream jump between them on every refresh.
    @Test func equalAreasSettleStably() {
        let a = window(100, width: 1280, height: 800)
        let b = window(101, width: 800, height: 1280)
        #expect(
            VideoWindowPicker.choose(
                windows: [a, b], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .window(id: 100, bundleID: "us.zoom.xos")
        )
    }

    /// The case that gave the feature its shape: recording starts while the
    /// call app is still on its launcher, and the launcher is the biggest
    /// window in the family. The meeting window — smaller, but the app's
    /// active one — must win anyway.
    @Test func anActiveWindowBeatsABiggerLauncher() {
        let launcher = window(110, width: 1920, height: 1080)
        let meeting = window(111, width: 1280, height: 720, active: true)
        #expect(
            VideoWindowPicker.choose(
                windows: [launcher, meeting], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .window(id: 111, bundleID: "us.zoom.xos")
        )
    }

    /// And the launcher strikes back: once the person clicks back into it,
    /// it is the app's active window again. The re-pick follows what the app
    /// itself says is active — there is no notion of "the real meeting" to
    /// prefer beyond what the app is showing.
    @Test func aLauncherTheUserClickedBackIntoIsChosenAgain() {
        let meeting = window(130, active: true)
        let launcher = window(131, width: 1920, height: 1080, active: true)
        #expect(
            VideoWindowPicker.choose(
                windows: [meeting, launcher], displays: [display],
                families: ["us.zoom"], mode: .window
            ) == .window(id: 131, bundleID: "us.zoom.xos")
        )
    }

    @Test func configValueReadsIntoTheMode() {
        #expect(VideoCaptureMode.from(nil) == .window)
        #expect(VideoCaptureMode.from("window") == .window)
        #expect(VideoCaptureMode.from("display") == .display)
        #expect(VideoCaptureMode.from("nonsense") == .window)
    }
}
