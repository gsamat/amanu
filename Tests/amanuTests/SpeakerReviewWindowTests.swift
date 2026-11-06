import AppKit
import Foundation
import Testing

@testable import amanu

@Suite(.serialized, .freshHome(config: #"{"keep_audio":true,"summary":{"enabled":false},"speaker_names":{"enabled":false}}"#))
@MainActor
struct SpeakerReviewWindowTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("amanu-review-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func session(in root: URL, name: String = "2026-11-06-100000-review") throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "files": ["source": "source.caf"], "title": name,
            "started": "2026-11-06T10:00:00Z", "duration_seconds": 12,
        ]).write(to: dir.appendingPathComponent("meta.json"))
        try TestAudio.writeTone(to: dir.appendingPathComponent("source.caf"), seconds: 12,
                                frequency: 220, sampleRate: 16_000)
        try Transcript(engine: "compatible", model: "test", created_at: "2026-11-06T10:20:00Z", segments: [
            .init(speaker: "c001:s0", start_ms: 0, end_ms: 1000, text: "Привет."),
            .init(speaker: "c001:s1", start_ms: 1000, end_ms: 2000, text: "Здравствуйте."),
            .init(speaker: "c001:s0", start_ms: 3000, end_ms: 11000, text: "Это самая длинная реплика первого участника."),
        ]).write(to: dir)
        return dir
    }

    private func offer(_ dir: URL) throws {
        try SpeakerReview.recordTranscript(dir, supportsDiarization: true)
        try SessionState.amend(dir, with: [SessionState.Key.speakerReview: [
            "transcript": try #require(SpeakerReview.transcriptID(dir)), "state": "reviewing",
            "owner_pid": ProcessInfo.processInfo.processIdentifier, "interactive": true,
        ]])
        try SessionClaim.acquire(dir, stage: .review)
    }

    @Test("A ready meeting opens Participants and shows both bounded audio samples")
    func participantsAndArchivedAudio() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        try offer(dir)
        defer { SessionClaim.release(dir) }
        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(dir)
        let views = try #require(window.view).allDescendants
        let tabs = try #require(views.compactMap { $0 as? NSTabView }.first)
        #expect(tabs.selectedTabViewItem?.identifier as? String == "speakers")
        let displayed = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        #expect(displayed.contains(localised("Participant 1", "Участник 1")))
        #expect(displayed.contains(localised("Participant 2", "Участник 2")))
        #expect(!displayed.contains("c001:"), "namespaces are persistence identifiers, not participant names")
        #expect(views.compactMap { $0 as? NSButton }.contains { $0.identifier?.rawValue == "confirm-speaker-review" })
        let audioButtons = views.compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("speaker-audio-") == true
        }
        #expect(audioButtons.count == 3, "first + longest for the first speaker, first for the second")
        _ = try TranscriptVersions.archiveCurrent(dir)
        let selector = try #require(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "transcript-versions"
        })
        // Make the old snapshot a distinct version without changing the source audio.
        let current = try #require(PostProcessor.readTranscript(dir))
        try Transcript(engine: current.engine, model: "new", created_at: "2026-11-06T10:21:00Z",
                       segments: current.segments).write(to: dir)
        window.sessionsChanged()
        await window.settled()
        selector.selectItem(at: 0)
        _ = selector.sendAction(selector.action!, to: selector.target)
        let oldAudioButtons = try #require(window.view).allDescendants.compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("speaker-audio-") == true
        }
        #expect(oldAudioButtons.count == 3, "archived words play from the session's retained audio")
        window.view?.window?.orderOut(nil)
    }

    @Test("Cancelling close or selection keeps review and its claim; quit confirms the whole queue")
    func reviewExitRequiresDecision() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(in: root)
        let second = try session(in: root, name: "2026-11-06-110000-review")
        try offer(first)
        try offer(second)
        defer { SessionClaim.release(first); SessionClaim.release(second) }
        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(first)
        await window.showSpeakerReview(second)
        var asked: [Int] = []
        window.confirmLeavingReview = { count in asked.append(count); return false }
        let panel = try #require(window.view?.window)
        #expect(!window.windowShouldClose(panel))
        #expect(SpeakerReview.isPending(first) && SessionClaim.isHeld(first))
        let table = try #require(window.view?.allDescendants.compactMap { $0 as? NSTableView }.first)
        #expect(!window.tableView(table, shouldSelectRow: table.selectedRow == 0 ? 1 : 0))
        #expect(SpeakerReview.isPending(first))
        #expect(asked == [2, 1])
        window.confirmLeavingReview = { count in asked.append(count); return true }
        #expect(await window.reviewBeforeTermination())
        #expect(asked.last == 2)
        #expect(!SpeakerReview.isPending(first) && !SpeakerReview.isPending(second))
        #expect(!SessionClaim.isHeld(first) && !SessionClaim.isHeld(second))
        await window.waitForPostReviewWork()
        await window.settled()
        panel.orderOut(nil)
    }

    @Test("A long participant list scrolls to the last person and keeps edits across resizing")
    func longParticipantListRemainsUsable() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        let segments = (0..<12).map { index in
            Transcript.Segment(
                speaker: "c001:s\(index)", start_ms: index * 1000,
                end_ms: index * 1000 + 700, text: "Реплика участника \(index + 1).")
        }
        try Transcript(engine: "compatible", model: "test", created_at: "2026-11-06T10:20:00Z",
                       segments: segments).write(to: dir)
        try offer(dir)
        defer { SessionClaim.release(dir) }

        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(dir)
        let panel = try #require(window.view?.window)
        panel.setContentSize(NSSize(width: 860, height: 560))
        panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(window.view?.allDescendants.compactMap { $0 as? NSScrollView }.first {
            $0.identifier?.rawValue == "participants-scroll"
        })
        let document = try #require(scroll.documentView)
        document.layoutSubtreeIfNeeded()
        #expect(document.bounds.height > scroll.contentView.bounds.height,
                "the list needs an actual scrollable document")

        func nameField(_ speaker: Int) throws -> NSTextField {
            try #require(window.view?.allDescendants.compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue.hasSuffix("\nc001:s\(speaker)") == true
            })
        }

        let last = try nameField(11)
        _ = last.scrollToVisible(last.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(document.visibleRect.intersects(last.convert(last.bounds, to: document)),
                "the final participant must be reachable at the minimum window size")
        let position = scroll.contentView.bounds.origin.y
        last.stringValue = "Мария Иванова"
        _ = last.sendAction(try #require(last.action), to: last.target)
        await window.settled()
        #expect(SpeakerNames.read(from: dir)?.speakers["c001:s11"]?.name == "Мария Иванова")
        #expect(try nameField(11).stringValue == "Мария Иванова")
        #expect(abs(scroll.contentView.bounds.origin.y - position) < 2,
                "saving a name should not send the reader back to the top")

        panel.setContentSize(NSSize(width: 1100, height: 760))
        panel.contentView?.layoutSubtreeIfNeeded()
        let afterResize = try nameField(11)
        _ = afterResize.scrollToVisible(afterResize.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(document.visibleRect.intersects(afterResize.convert(afterResize.bounds, to: document)))
        #expect(afterResize.stringValue == "Мария Иванова")
        panel.orderOut(nil)
    }

    @Test("A background update to another meeting preserves an unfinished name and scroll position")
    func anotherMeetingUpdateKeepsInProgressEdit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try session(in: root)
        let other = try session(in: root, name: "2026-11-06-090000-review")
        let segments = (0..<12).map { index in
            Transcript.Segment(
                speaker: "c001:s\(index)", start_ms: index * 1000,
                end_ms: index * 1000 + 700, text: "Реплика участника \(index + 1).")
        }
        try Transcript(engine: "compatible", model: "test", created_at: "2026-11-06T10:20:00Z",
                       segments: segments).write(to: current)
        try offer(current)
        defer { SessionClaim.release(current) }

        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(current)
        let panel = try #require(window.view?.window)
        panel.setContentSize(NSSize(width: 860, height: 560))
        panel.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(window.view?.allDescendants.compactMap { $0 as? NSScrollView }.first {
            $0.identifier?.rawValue == "participants-scroll"
        })
        let field = try #require(window.view?.allDescendants.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue.hasSuffix("\nc001:s11") == true
        })
        let initialPosition = scroll.contentView.bounds.origin.y
        _ = field.scrollToVisible(field.bounds)
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin.y
        #expect(abs(position - initialPosition) > 2, "the test must exercise an actual scrolled position")
        field.stringValue = "Несохранённое имя"
        #expect(SpeakerNames.read(from: current)?.speakers["c001:s11"]?.name == nil)

        try SessionState.amend(other, with: ["title": "Another meeting changed"])
        window.sessionsChanged()
        await window.settled()

        let sameField = try #require(window.view?.allDescendants.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue.hasSuffix("\nc001:s11") == true
        })
        #expect(sameField === field, "the edit and its field editor must survive unrelated updates")
        #expect(sameField.stringValue == "Несохранённое имя")
        #expect(abs(scroll.contentView.bounds.origin.y - position) < 2)
        #expect(SpeakerNames.read(from: current)?.speakers["c001:s11"]?.name == nil,
                "the background update must not commit a pending edit")
        panel.orderOut(nil)
    }

    @Test("A changed transcript rebuilds the current participant list")
    func updatedTranscriptRebuildsParticipants() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        let window = RecordingsWindow(root: root)
        let panel = try #require(window.view?.window)
        panel.orderFront(nil)
        await window.settled()
        let tabs = try #require(window.view?.allDescendants.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "speakers")
        let before = try #require(PostProcessor.readTranscript(dir))
        var segments = before.segments
        segments.append(.init(speaker: "c001:s2", start_ms: 11000, end_ms: 11500,
                              text: "Ещё один участник."))
        try Transcript(engine: before.engine, model: before.model,
                       created_at: before.created_at, segments: segments).write(to: dir)
        window.sessionsChanged()
        await window.settled()
        let fields = try #require(window.view).allDescendants.compactMap { $0 as? NSTextField }
        #expect(fields.contains { $0.identifier?.rawValue.hasSuffix("\nc001:s2") == true },
                "a new speaker must appear after an external transcript update")
        #expect(fields.contains { $0.stringValue == localised("Participants · 3", "Участники · 3") })
        panel.orderOut(nil)
    }

    @Test("The first participant stays visible when the summary-update action appears")
    func summaryUpdateKeepsFirstParticipantVisible() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        try Data("An earlier summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        PostProcessor.rename("c001:s0", to: "Мария", in: dir)
        let window = RecordingsWindow(root: root)
        let panel = try #require(window.view?.window)
        panel.setContentSize(NSSize(width: 860, height: 560))
        panel.orderFront(nil)
        await window.settled()
        let tabs = try #require(window.view?.allDescendants.compactMap { $0 as? NSTabView }.first)
        tabs.selectTabViewItem(withIdentifier: "speakers")
        panel.contentView?.layoutSubtreeIfNeeded()
        let views = try #require(window.view).allDescendants
        let update = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "update-summary"
        })
        #expect(!update.isHidden)
        let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first {
            $0.identifier?.rawValue == "participants-scroll"
        })
        let field = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue.hasSuffix("\nc001:s0") == true
        })
        let visible = scroll.contentView.bounds.insetBy(dx: -1, dy: -1)
        #expect(visible.contains(field.convert(field.bounds, to: scroll.contentView)),
                "the summary action must not push the first name field out of view")
        #expect(field.stringValue == "Мария")
        panel.orderOut(nil)
    }

    @Test("Review temporarily gives the participants more space and restores the list split")
    func reviewTemporarilyResizesTheSplit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        try offer(dir)
        defer { SessionClaim.release(dir) }
        let window = RecordingsWindow(root: root)
        let panel = try #require(window.view?.window)
        panel.setContentSize(NSSize(width: 980, height: 700))
        panel.contentView?.layoutSubtreeIfNeeded()
        let split = try #require(window.view?.allDescendants.compactMap { $0 as? NSSplitView }.first)
        split.setPosition(250, ofDividerAt: 0)
        panel.contentView?.layoutSubtreeIfNeeded()
        let original = try #require(split.arrangedSubviews.first).frame.height
        #expect(original > 165, "the fixture starts with room to reclaim")
        let autosave = split.autosaveName

        await window.showSpeakerReview(dir)
        panel.contentView?.layoutSubtreeIfNeeded()
        let duringReview = try #require(split.arrangedSubviews.first).frame.height
        #expect(duringReview < original)
        #expect(split.autosaveName == nil, "a temporary review layout must not overwrite the saved split")

        window.completeSpeakerReview()
        await window.waitForReviewWork()
        await window.waitForPostReviewWork()
        await window.settled()
        panel.contentView?.layoutSubtreeIfNeeded()
        let restored = try #require(split.arrangedSubviews.first).frame.height
        #expect(abs(restored - original) < 2)
        #expect(split.autosaveName == autosave)
        panel.orderOut(nil)
    }

    @Test("VoiceOver distinguishes each participant's name field and audio examples")
    func participantControlsHaveDistinctAccessibilityLabels() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        try offer(dir)
        defer { SessionClaim.release(dir) }
        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(dir)
        let views = try #require(window.view).allDescendants
        let fields = views.compactMap { $0 as? NSTextField }
        let buttons = views.compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("speaker-audio-") == true
        }
        for index in 0..<2 {
            let label = localised("Participant \(index + 1)", "Участник \(index + 1)")
            let field = try #require(fields.first {
                $0.identifier?.rawValue.hasSuffix("\nc001:s\(index)") == true
            })
            #expect(field.accessibilityLabel()?.localizedCaseInsensitiveContains(label) == true,
                    "the name field should identify its participant")
            #expect(buttons.contains { $0.accessibilityLabel()?.localizedCaseInsensitiveContains(label) == true },
                    "the audio example should identify its participant")
        }
        #expect(Set(buttons.compactMap { $0.accessibilityLabel() }).count == buttons.count,
                "first and longest samples must be distinguishable as well")
        window.view?.window?.orderOut(nil)
    }

    // This exercises the shared AppKit field editor and key window. Other
    // suites also drive NSApplication, so run it in its own test process.
    @Test("Clicking Create summary saves an active name edit without pressing Return",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_ISOLATED_FIELD_EDITOR_TEST"] == "1"))
    func activeNameEditIsSavedByReviewAction() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(in: root)
        try offer(dir)
        defer { SessionClaim.release(dir) }
        let window = RecordingsWindow(root: root)
        await window.showSpeakerReview(dir)
        let fields = try #require(window.view).allDescendants.compactMap { $0 as? NSTextField }
        let name = try #require(fields.first { $0.identifier?.rawValue.hasSuffix("\nc001:s0") == true })
        let panel = try #require(window.view?.window)
        // SwiftPM's test runner has no active application window.
        #expect(panel.makeFirstResponder(name))
        let editor = try #require(name.currentEditor() as? NSTextView)
        editor.string = "Мария"
        let create = try #require(window.view?.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "confirm-speaker-review"
        })
        create.performClick(nil)
        await window.waitForReviewWork()
        await window.waitForPostReviewWork()
        await window.settled()
        #expect(SpeakerNames.read(from: dir)?.speakers["c001:s0"]?.name == "Мария")
        #expect(!SpeakerReview.isPending(dir))
        #expect(!PostProcessor.summaryNeedsManualUpdate(dir), "review names belong to the new summary")
        // Once a summary exists, a later correction is explicit paid work.
        // Use the same live window, as a person editing after review would.
        try Data("The existing summary".utf8).write(to: dir.appendingPathComponent("summary.md"))
        let correction = try #require(window.view?.allDescendants.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue.hasSuffix("\nc001:s0") == true
        })
        correction.stringValue = "Мария Иванова"
        _ = correction.sendAction(correction.action!, to: correction.target)
        await window.settled()
        let update = try #require(window.view?.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "update-summary"
        })
        #expect(update.superview != nil && !update.isHidden)
        #expect(PostProcessor.summaryNeedsManualUpdate(dir))
        panel.orderOut(nil)
    }
}
