import AppKit
import Testing

@testable import amanu

/// The status window against the one thing its layout can get wrong.
///
/// Its rows come and go — the transcription line, the line saying why it is
/// not recording, the live section — and twice now a running copy has been
/// found drawing the live transcript's checkbox across the Manage recordings
/// button. Both times the rows disagreed with the window they were in: once
/// because the window was asked to be shorter than they are, once because the
/// rows were laid out for a window 22 points shorter than the one they were
/// in and stayed that way through a resize.
///
/// So what this checks is the arrangement itself — every row exactly the
/// stack's spacing below the one above it — rather than the window's height,
/// which is only one of the ways it has gone wrong.
@Suite(.serialized)
struct StatusWindowLayoutTests {
    @Test("Live speaker labels use the adaptive label colour")
    @MainActor
    func liveSpeakerLabelsFollowTheAppearance() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        let previousLanguage = InterfaceLanguage.current
        NSApp.appearance = NSAppearance(named: .darkAqua)
        InterfaceLanguage.current = .english
        defer {
            NSApp.appearance = previousAppearance
            InterfaceLanguage.current = previousLanguage
        }

        let window = StatusWindow()
        let panel = try #require(window.view?.window)
        panel.appearance = NSAppearance(named: .darkAqua)
        window.updateLive(.init(
            isRecording: true,
            isEnabled: true,
            entries: [
                .speech(.init(
                    speaker: .them,
                    text: "Amanu",
                    startMilliseconds: 0,
                    isProvisional: false,
                )),
                .speech(.init(
                    speaker: .you,
                    text: "Amanu",
                    startMilliseconds: 1,
                    isProvisional: false,
                )),
            ],
            status: .live
        ))

        let transcript = try #require(firstTextView(in: window.view))
        for label in ["Them", "You"] {
            let range = (transcript.string as NSString).range(of: label)
            try #require(range.location != NSNotFound)
            let colour = transcript.textStorage?.attribute(
                .foregroundColor,
                at: range.location,
                effectiveRange: nil
            ) as? NSColor
            #expect(colour == .labelColor, "\(label) does not follow the window appearance")
        }

        withExtendedLifetime(window) {}
    }

    @Test("Every row the status window can show sits under the row above it")
    @MainActor
    func everyStateIsAnArrangement() throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame amanu.status")
        let window = StatusWindow()
        let panel = try #require(window.view?.window)
        window.show()

        let speech = LiveTranscriptState.Entry.speech(.init(
            speaker: .you, text: "amanu", startMilliseconds: 0, isProvisional: false))

        // Idle, which is how the window sits all day. The transcription line
        // is never spoken to here, exactly as it is never spoken to on a Mac
        // with nothing to transcribe.
        window.update(state: .idle, elapsed: nil)
        window.updateAutoRecord(enabled: true, decision: nil)
        window.updateLive(.init(isRecording: false, isEnabled: false, entries: [], status: .idle))
        check(window, panel, "idle, and never told about transcription")

        // A recording, which adds the line saying why it is running.
        window.update(state: .recording, elapsed: "3:06")
        window.updateAutoRecord(enabled: true, decision: "manual recording in progress")
        window.updateLive(.init(isRecording: true, isEnabled: false, entries: [], status: .paused))
        check(window, panel, "recording, live off")

        // And the transcription line on top of that.
        window.updateTranscription("transcribing 2026.08.21-1000")
        check(window, panel, "recording while transcribing")

        // The transcript borrowing the height, and giving it back.
        window.updateLive(.init(
            isRecording: true, isEnabled: true, entries: [speech], status: .live))
        check(window, panel, "recording, transcript open")
        window.update(state: .idle, elapsed: nil)
        window.updateTranscription(nil)
        window.updateAutoRecord(enabled: true, decision: nil)
        window.updateLive(.init(
            isRecording: false, isEnabled: true, entries: [speech], status: .idle))
        check(window, panel, "stopped, transcript folded away")

        // A window somebody has dragged about, and one squeezed smaller than
        // its rows: fewer rows may fit, but no two may share a place.
        for height in [420.0, 300.0, 240.0, 180.0, 320.0] as [CGFloat] {
            var frame = panel.frame
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: false)
            window.updateAutoRecord(enabled: true, decision: "mic held by corespeechd")
            check(window, panel, "window forced to \(height)", fitting: false)
        }

        withExtendedLifetime(window) {}
    }

    /// Every visible row exactly `spacing` below the one above it, the first
    /// at the top inset, and — unless the window has been forced smaller than
    /// its rows — a window tall enough to hold them.
    @MainActor
    private func check(
        _ window: StatusWindow, _ panel: NSWindow, _ state: String, fitting: Bool = true
    ) {
        let rows = window.rowsView
        rows.layoutSubtreeIfNeeded()
        let shown = rows.views.filter { !$0.isHidden }
        var expected = rows.edgeInsets.top
        for row in shown {
            let top = rows.bounds.height - row.frame.maxY
            #expect(abs(top - expected) < 0.5,
                    "\(state): \(describe(row)) is at \(top), not \(expected)")
            expected = top + row.frame.height + rows.spacing
        }
        guard fitting else { return }
        #expect(rows.fittingSize.height <= panel.contentLayoutRect.height + 0.5,
                "\(state): the window is shorter than what is in it")
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

    @MainActor
    private func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        for child in view.subviews {
            if let text = firstTextView(in: child) { return text }
        }
        return nil
    }
}
