import AppKit
import Testing

@testable import amanu

/// The feather's menu, in order.
///
/// This is the whole control surface for a recorder that lives in the menu bar,
/// and its arrangement is a decision rather than the order the items happened
/// to be added in: what is happening, what to do about it, the switch that
/// decides whether it happens by itself, the places to look at it, and the way
/// out. Reading it back here is what keeps a later item from landing in the
/// middle of that story — and what says, in one place, which controls a meeting
/// actually offers while it is running.
@MainActor
@Suite("The feather's menu, in order")
struct MenuBarMenuTests {
    /// A menu as the app leaves it after the first run: Setup… and Check for
    /// updates… are the two items that come and go, and both are away.
    private static func settled() -> MenuBarController {
        let menuBar = MenuBarController(visible: false)
        menuBar.setupAvailable(false)
        menuBar.updatesAvailable(false)
        return menuBar
    }

    /// Everything below the recording controls. The same in all three states:
    /// a switch, the three places amanu can be opened from, the two items that
    /// change how it behaves, and the way out.
    private static let tail = [
        "",
        "Record meetings automatically",
        "",
        "Show Amanu window",
        "Open recordings folder",
        "Manage recordings…",
        "",
        "About Amanu",
        "Settings…",
        "",
        "Quit Amanu",
    ]

    @Test("At rest it offers the meeting, the meeting with the picture, and the way to look")
    func idleArrangement() {
        let menuBar = Self.settled()
        menuBar.update(state: .idle, elapsed: nil)

        #expect(menuBar.offeredItemTitles == ["idle"] + [
            "",
            "Start recording",
            "Start recording with video",
        ] + Self.tail)
        withExtendedLifetime(menuBar) {}
    }

    /// The two start commands give way to the two controls a running meeting
    /// needs, in the slots they were in — so the item under the clock is always
    /// the one to reach for.
    @Test("A running meeting offers pause, the picture, and the way to stop")
    func recordingArrangement() {
        let menuBar = Self.settled()
        menuBar.update(state: .recording, elapsed: "1:23")
        menuBar.updateVideo(visible: true, active: false)

        #expect(menuBar.offeredItemTitles == ["● recording · 1:23"] + [
            "",
            "Pause recording",
            "Record video",
            "Stop recording",
        ] + Self.tail)
        withExtendedLifetime(menuBar) {}
    }

    @Test("With the picture being written, the item offers the way out of it")
    func recordingWithVideoArrangement() {
        let menuBar = Self.settled()
        menuBar.update(state: .recording, elapsed: "1:23")
        menuBar.updateVideo(visible: true, active: true)

        #expect(menuBar.offeredItemTitles.contains("Stop recording video"))
        #expect(!menuBar.offeredItemTitles.contains("Record video"))
        withExtendedLifetime(menuBar) {}
    }

    /// One video file per session: once the picture has been stopped by hand,
    /// there is nothing for the item to offer, and an item that can only do
    /// nothing is not offered.
    @Test("After the video was stopped there is no third line")
    func videoCannotStartAgain() {
        let menuBar = Self.settled()
        menuBar.update(state: .recording, elapsed: "1:23")
        menuBar.updateVideo(visible: false, active: false)

        #expect(menuBar.offeredItemTitles == ["● recording · 1:23"] + [
            "",
            "Pause recording",
            "Stop recording",
        ] + Self.tail)
        withExtendedLifetime(menuBar) {}
    }

    @Test("A paused meeting offers the way back into it")
    func pausedArrangement() {
        let menuBar = Self.settled()
        menuBar.update(state: .paused, elapsed: "1:23")
        menuBar.updateVideo(visible: true, active: false)

        #expect(menuBar.offeredItemTitles.prefix(3) == [
            "❙❙ paused · 1:23", "", "Resume recording",
        ])
        #expect(menuBar.offeredItemTitles.contains("Stop recording"))
        withExtendedLifetime(menuBar) {}
    }

    /// The reason behind the switch belongs to the switch, directly under it —
    /// reading "why did that call not record" should not mean hunting for a
    /// line somewhere else in the menu.
    @Test("The clock line says when the picture is being recorded too")
    func recordingWithVideoNamesThePicture() {
        let menuBar = Self.settled()
        menuBar.update(state: .recording, elapsed: "1:23", videoActive: true)

        #expect(menuBar.offeredItemTitles.first == "● recording with video · 1:23")
        withExtendedLifetime(menuBar) {}
    }

    @Test("The auto-record decision sits under the switch it explains")
    func autoRecordDecisionStaysWithItsSwitch() throws {
        let menuBar = Self.settled()
        menuBar.update(state: .idle, elapsed: nil)
        menuBar.updateAutoRecord(enabled: true, decision: "manual recording in progress")

        let titles = menuBar.offeredItemTitles
        let switchAt = try #require(titles.firstIndex(of: "Record meetings automatically"))
        #expect(titles[switchAt + 1] == "   manual recording in progress")
        withExtendedLifetime(menuBar) {}
    }

    @Test("The clock and the recording controls are the first thing in the menu")
    func statusLineStaysAtTheTop() {
        let menuBar = Self.settled()
        menuBar.update(state: .recording, elapsed: "9:59")
        menuBar.updateTranscription("transcribing amanu")

        #expect(menuBar.offeredItemTitles.prefix(2) == ["● recording · 9:59", "transcribing amanu"])
        withExtendedLifetime(menuBar) {}
    }

    /// Each line drives the thing it says, and the one sharing that is
    /// deliberate: Start recording and Stop recording both arrive as `onToggle`,
    /// which is what lets them share Command-R without the shortcut being able
    /// to mean the wrong one of the two.
    @Test("Every item drives the action it is named after")
    func eachItemDrivesItsOwnAction() {
        let menuBar = Self.settled()
        var calls: [String] = []
        menuBar.onToggle = { calls.append("toggle") }
        menuBar.onTogglePause = { calls.append("pause") }
        menuBar.onStartWithVideo = { calls.append("withVideo") }
        menuBar.onToggleVideo = { calls.append("video") }

        menuBar.update(state: .idle, elapsed: nil)
        #expect(menuBar.performOfferedItem(titled: "Start recording"))
        #expect(menuBar.performOfferedItem(titled: "Start recording with video"))

        menuBar.update(state: .recording, elapsed: "0:10")
        menuBar.updateVideo(visible: true, active: false)
        #expect(menuBar.performOfferedItem(titled: "Pause recording"))
        #expect(menuBar.performOfferedItem(titled: "Record video"))
        #expect(menuBar.performOfferedItem(titled: "Stop recording"))

        // The way back into a paused meeting is the same item, and the way into
        // a recording is not on offer while one is running.
        menuBar.update(state: .paused, elapsed: "0:11")
        #expect(menuBar.performOfferedItem(titled: "Resume recording"))
        #expect(!menuBar.performOfferedItem(titled: "Start recording"))

        #expect(calls == ["toggle", "withVideo", "pause", "video", "toggle", "pause"])
        withExtendedLifetime(menuBar) {}
    }
}
