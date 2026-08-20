import AppKit
import Testing

@testable import amanu

/// The status window against the one thing its layout can get wrong.
///
/// Its rows come and go — the transcription line, the line saying why it is
/// not recording, the live section — and its height was three constants that
/// knew nothing about them. A window frame shorter than its content view does
/// not squeeze the content: the content keeps the height its constraints ask
/// for and slides up out of the content rect, so the rows at the bottom are
/// drawn across each other. That is what this walks the window looking for.
@Suite(.serialized)
struct StatusWindowLayoutTests {
    @Test("Every row the status window can show fits in the window")
    @MainActor
    func everyStateFits() throws {
        _ = NSApplication.shared
        let window = StatusWindow()
        let content = try #require(window.view)
        let panel = try #require(content.window)

        func check(_ state: String) {
            content.layoutSubtreeIfNeeded()
            #expect(content.fittingSize.height <= panel.contentLayoutRect.height + 0.5,
                    "\(state): the window is shorter than what is in it")
            for row in content.subviews where !row.isHidden {
                #expect(row.frame.minY >= -0.5 && row.frame.maxY <= content.bounds.height + 0.5,
                        "\(state): a row is outside the window")
            }
            #expect(overlaps(in: content).isEmpty,
                    "\(state): rows drawn across each other: \(overlaps(in: content))")
        }

        // Idle, which is how the window sits all day.
        window.update(state: .idle, elapsed: nil)
        window.updateTranscription("transcribes on this Mac")
        window.updateAutoRecord(enabled: true, decision: nil)
        window.updateLive(.init(isRecording: false, isEnabled: true, entries: [], status: .idle))
        check("idle")

        // A recording, which adds the line saying why it is running. This is
        // the one that overlapped: the row appeared, the window did not grow.
        window.update(state: .recording, elapsed: "3:06")
        window.updateAutoRecord(enabled: true, decision: "manual recording in progress")
        window.updateLive(.init(
            isRecording: true, isEnabled: false, entries: [], status: .paused))
        check("recording, live off")

        // The transcript borrowing the height, and giving it back.
        let speech = LiveTranscriptState.Entry.speech(.init(
            speaker: .you, text: "amanu", startMilliseconds: 0, isProvisional: false))
        window.updateLive(.init(
            isRecording: true, isEnabled: true, entries: [speech], status: .live))
        check("recording, transcript open")

        window.update(state: .idle, elapsed: nil)
        window.updateAutoRecord(enabled: true, decision: nil)
        window.updateLive(.init(
            isRecording: false, isEnabled: true, entries: [speech], status: .idle))
        check("stopped, transcript folded away")

        withExtendedLifetime(window) {}
    }

    /// Which rows share vertical space with the row above them, by the words
    /// on them, so a failure says what collided rather than that something did.
    @MainActor
    private func overlaps(in content: NSView) -> [String] {
        let rows = content.subviews
            .filter { !$0.isHidden }
            .sorted { $0.frame.maxY > $1.frame.maxY }
        var found: [String] = []
        for (above, below) in zip(rows, rows.dropFirst())
        where below.frame.maxY > above.frame.minY + 0.5 {
            found.append("\(describe(above)) / \(describe(below))")
        }
        return found
    }

    @MainActor
    private func describe(_ view: NSView) -> String {
        if let button = view as? NSButton { return button.title }
        if let field = view as? NSTextField { return field.stringValue }
        if let stack = view as? NSStackView {
            return stack.views.map { describe($0) }.joined(separator: "+")
        }
        return "\(type(of: view))"
    }
}
