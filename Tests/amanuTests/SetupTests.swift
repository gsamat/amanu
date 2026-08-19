import AppKit
import Foundation
import Testing
@testable import amanu

@Suite(.serialized)
struct SetupTests {
    @Test("Completing setup survives a later process and reset makes it pending again")
    func completionRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-setup-test-\(UUID().uuidString)")
        let state = root.appendingPathComponent("nested/setup.json")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(SetupState.isPending(at: state))

        SetupState.markCompleted(at: state)
        #expect(SetupState.completedVersion(at: state) == 1)
        #expect(!SetupState.isPending(at: state))

        SetupState.reset(at: state)
        #expect(SetupState.isPending(at: state))
    }

    @Test("The setup subcommand routes to the setup launcher")
    func setupCommandIsRegistered() throws {
        let command = try Amanu.parseAsRoot(["setup"])
        #expect(command is Setup)
    }

    @Test("System-audio setup retries silence and refused taps, but not a heard tone")
    @MainActor
    func systemAudioRetryPolicy() {
        #expect(SetupPermissions.needsSystemAudioTest(nil))
        #expect(SetupPermissions.needsSystemAudioTest(.silent))
        #expect(SetupPermissions.needsSystemAudioTest(.refused("permission denied")))
        #expect(!SetupPermissions.needsSystemAudioTest(.heard))
    }

    @Test("A heard tone is believed for a month, and then measured again")
    @MainActor
    func systemAudioMemory() {
        let heard = Date(timeIntervalSince1970: 1_000_000)
        let week = heard.addingTimeInterval(7 * 24 * 60 * 60)
        let quarter = heard.addingTimeInterval(90 * 24 * 60 * 60)

        #expect(SetupPermissions.rememberedSystemAudio(heardAt: heard, now: week) == .heard)
        #expect(SetupPermissions.rememberedSystemAudio(heardAt: heard, now: quarter) == nil)
        #expect(SetupPermissions.rememberedSystemAudio(heardAt: nil, now: week) == nil)
        // A clock that went backwards is not evidence of anything.
        #expect(SetupPermissions.rememberedSystemAudio(
            heardAt: quarter, now: heard) == nil)
    }

    @Test("The remembered tone survives marking setup complete, and vice versa")
    func systemAudioMemoryRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = dir.appendingPathComponent("setup.json")

        let heard = Date(timeIntervalSince1970: 1_700_000_000)
        SetupState.rememberSystemAudioHeard(now: heard, at: state)
        SetupState.markCompleted(at: state)

        #expect(SetupState.systemAudioHeardAt(at: state) == heard)
        #expect(SetupState.isPending(at: state) == false)

        // `amanu setup` resets the window's own state; a measurement of the
        // machine is not part of that.
        SetupState.reset(at: state)
        #expect(SetupState.isPending(at: state))
        #expect(SetupState.systemAudioHeardAt(at: state) == heard)
    }

    @Test("First-run setup bypasses a denied microphone, not a broken recordings folder")
    func doctorRepairBoundary() {
        let microphone = Check(name: "microphone", status: .fail("denied"), remediation: nil)
        let recordings = Check(
            name: "recordings folder", status: .fail("not writable"), remediation: nil)

        #expect(DoctorReport.canContinueIntoSetup([microphone]))
        #expect(!DoctorReport.canContinueIntoSetup([microphone, recordings]))
    }

    @Test("A detected tool's status is visible inside its choice card")
    @MainActor
    func choiceCardShowsStatus() {
        let card = ChoiceCard(id: "tool", title: "Tool", detail: "A backend")
        card.report("answers · 1.0", good: true)

        let labels = card.allDescendants
            .filter { !$0.isHidden }
            .compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("answers · 1.0"))
    }

    /// Catches the border looking clickable while only the small radio title
    /// actually responds.
    @Test("Clicking the body of a choice card selects it")
    @MainActor
    func choiceCardBodySelects() throws {
        let card = ChoiceCard(id: "tool", title: "Tool", detail: "A backend")
        var selected: String?
        card.onSelect = { selected = $0 }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 150, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))

        card.mouseDown(with: event)

        #expect(selected == "tool")
    }

    /// Static labels must behave as part of the card, while controls placed
    /// inside it keep receiving their own clicks.
    /// The regression this catches made every card except the leftmost one
    /// inert: `hitTest` is asked in the superview's coordinates, and a test
    /// against `bounds` answers "not mine" for anything not at the origin.
    @Test("A card away from the origin of its row still takes the click")
    @MainActor
    func choiceCardAwayFromOriginIsHit() throws {
        let first = ChoiceCard(id: "first", title: "First", detail: "A backend")
        let second = ChoiceCard(id: "second", title: "Second", detail: "Another")
        let row = NSStackView(views: [first, second])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        row.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        row.layoutSubtreeIfNeeded()

        #expect(second.frame.minX > 0, "the second card should not be at the origin")
        let insideSecond = NSPoint(x: second.frame.midX, y: second.frame.midY)
        #expect(row.hitTest(insideSecond) != nil)
        #expect(second.hitTest(insideSecond) != nil)
        // And the first card must not claim a point that belongs to its neighbour.
        #expect(first.hitTest(insideSecond) == nil)
    }

    @Test("Choice-card labels route clicks to the whole card")
    @MainActor
    func choiceCardLabelsArePartOfHitArea() throws {
        let accessory = NSButton(title: "Install", target: nil, action: nil)
        let card = ChoiceCard(
            id: "tool", title: "Tool", detail: "A backend", accessories: [accessory])
        card.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
        card.layoutSubtreeIfNeeded()

        let detail = try #require(card.allDescendants.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "A backend" })
        let pointOnDetail = card.convert(
            NSPoint(x: detail.bounds.midX, y: detail.bounds.midY), from: detail)
        let pointOnAccessory = card.convert(
            NSPoint(x: accessory.bounds.midX, y: accessory.bounds.midY), from: accessory)

        #expect(card.hitTest(pointOnDetail) === card)
        #expect(card.hitTest(pointOnAccessory) === accessory)
    }

    /// It was the one checkbox in a window of switches, and a checkbox's
    /// title is part of the checkbox. A switch with a dead label beside it
    /// would be a smaller target than the thing it replaced, so the label
    /// still has to work.
    @Test("Keep Audio is a switch, and its label still toggles it")
    @MainActor
    func keepAudioLabelTogglesItsSwitch() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let label = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Keep the audio after transcribing" })
        let words = try #require(label.superview as? NSStackView)
        let row = try #require(words.superview as? NSStackView)
        let toggle = try #require(row.arrangedSubviews.compactMap { $0 as? NSSwitch }.first)
        let recognizer = try #require(words.gestureRecognizers.first)

        #expect(recognizer.target === toggle)
        #expect(toggle.target != nil, "a switch nobody listens to writes nothing")

        // Unhooked first: this test is about the label reaching the switch,
        // and the action behind it writes to the config file of whoever is
        // running the suite.
        toggle.target = nil
        toggle.action = nil
        toggle.state = .off
        toggle.toggleFromItsLabel()

        #expect(toggle.state == .on)
    }

    /// A row that still had a button came out taller than its neighbours, and
    /// since everything in a row is aligned to the top the extra height
    /// landed under the text — which is how the Calendar row came to look
    /// further from System audio than the rest of the list.
    @Test("Rows carrying one line are the same height, button or no button")
    @MainActor
    func accessRowsAreOneHeight() throws {
        let rows = [
            AccessRow(title: "Microphone", detail: "Your side of the call.", action: "Allow"),
            AccessRow(title: "System audio", detail: "", action: "Allow and test"),
            AccessRow(title: "Calendar", detail: "Names the folder.", action: "Allow"),
        ]
        let box = SetupLayout.box(rows)
        // Granted, as they are on a Mac that has been through setup: the
        // first and last lose their button, the middle one keeps "Test
        // again" because macOS will not report that grant.
        rows[0].update(.granted)
        rows[1].update(.granted, note: "heard the tone", action: "Test again")
        rows[2].update(.granted)
        box.frame = NSRect(x: 0, y: 0, width: 690, height: 300)
        box.layoutSubtreeIfNeeded()

        #expect(rows[0].frame.height >= SetupLayout.rowHeight)
        #expect(rows[1].frame.height == rows[0].frame.height)
        #expect(rows[2].frame.height == rows[0].frame.height)
    }

    /// AppKit leaves the far inset out of a stack's fitting height when the
    /// stack is aligned to one edge, so a row aligned to the top came out
    /// `insets.top + content` tall and nothing else: the last line of a
    /// wrapping detail sat flush with the bottom of the row, and the tails of
    /// its p's and q's touched the hairline under it — or, in the last row of
    /// a box, the border.
    @Test("A row whose detail wraps keeps the inset under its last line")
    @MainActor
    func wrappingRowKeepsItsBottomInset() throws {
        let words = SetupLayout.detail(
            "Nvidia parakeet, 460 MB download and disk usage. Nothing leaves the "
                + "machine, and it works with no network at all.", lines: 2, width: 520)
        let row = SetupLayout.row(
            leading: NSSwitch(),
            title: SetupLayout.title("On this Mac"),
            detail: words,
            trailing: [SetupLayout.status("downloaded")])
        let box = SetupLayout.box([row])
        box.frame = NSRect(x: 0, y: 0, width: 690, height: 200)
        box.layoutSubtreeIfNeeded()

        let content = try #require(words.superview)
        let placed = row.convert(content.bounds, from: content)
        #expect(placed.height > SetupLayout.rowHeight,
                "the detail has to have wrapped, or this measures nothing")
        #expect(placed.minY == SetupLayout.rowInsets.bottom)
        #expect(row.frame.height - placed.maxY == SetupLayout.rowInsets.top)
    }

    /// The same, for the hand-built row in the Access list: **Start at login**
    /// is the one that still explains itself on a Mac that has been through
    /// none of this.
    @Test("An Access row that is still explaining itself keeps its bottom inset")
    @MainActor
    func wrappingAccessRowKeepsItsBottomInset() throws {
        let row = AccessRow(
            title: "Start at login",
            detail: "So a meeting is never missed because nobody opened amanu, and "
                + "this sentence is long enough to need a second line.",
            action: "Install")
        let box = SetupLayout.box([row])
        row.update(.notAsked)
        box.frame = NSRect(x: 0, y: 0, width: 690, height: 200)
        box.layoutSubtreeIfNeeded()

        let stack = try #require(row.subviews.first)
        let text = try #require(stack.subviews.compactMap { $0 as? NSStackView }.first)
        let placed = row.convert(text.bounds, from: text)
        #expect(placed.height > SetupLayout.rowHeight,
                "the detail has to have wrapped, or this measures nothing")
        #expect(placed.minY == SetupLayout.rowInsets.bottom)
        #expect(row.frame.height - placed.maxY == SetupLayout.rowInsets.top)
    }

    /// Ollama is the one row in the window that `ChoiceCard` builds itself,
    /// and it had the same complaint as the wrapping rows in a milder form: a
    /// stack whose height nobody stated came out two points short of its own
    /// insets, and `.centerY` split the shortfall between top and bottom. It
    /// gets the same answer as every other row rather than a second one.
    @Test("The compact card is a row, and keeps a row's insets")
    @MainActor
    func compactCardKeepsRowInsets() throws {
        let card = ChoiceCard(
            id: "ollama", title: "Ollama", detail: "No account, no network.",
            accessories: [], compact: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 690, height: 100))
        host.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let stack = try #require(card.subviews.compactMap { $0 as? NSStackView }.first)
        let heading = try #require(stack.arrangedSubviews.first)
        let placed = card.convert(heading.bounds, from: heading)

        #expect(card.frame.height >= SetupLayout.rowHeight)
        #expect(placed.minY >= SetupLayout.rowInsets.bottom)
        #expect(card.frame.height - placed.maxY >= SetupLayout.rowInsets.top)
    }

    @Test("A chosen card reports bad news as a problem, an unchosen one as a note")
    @MainActor
    func chosenCardColoursItsBadNews() throws {
        let card = ChoiceCard(id: "claude-cli", title: "Claude Code", detail: "No key.")
        card.report("not here")
        let label = try #require(card.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "not here" })

        #expect(label.textColor == .secondaryLabelColor)
        card.isSelected = true
        #expect(label.textColor == .systemOrange)
        // Good news is what the caller says it is, rather than what the words
        // happen to start with — a card whose colour was read out of its own
        // text would go grey in the other language.
        card.report("answers · 1.0", good: true)
        #expect(label.textColor == .systemGreen)
    }

    /// The transcription section is two switches, and a switch nobody wired
    /// is the defect this file exists because of — the Summaries one shipped
    /// that way and silently summarised meetings that had been switched off.
    @Test("Both transcription switches are wired to something")
    @MainActor
    func transcriptionSwitchesAreWired() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })

        for title in ["In the cloud", "On this Mac"] {
            let label = try #require(panel.contentView?.allDescendants
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == title })
            // title → words stack → the row that carries the switch.
            let row = try #require(label.superview?.superview as? NSStackView)
            let toggle = try #require(row.arrangedSubviews.first as? NSSwitch)
            #expect(toggle.target != nil, "\(title) has no target")
            #expect(toggle.action != nil, "\(title) has no action")
        }
    }

    /// Both providers are on screen whether or not the cloud is switched on,
    /// and each says what an hour of meeting costs: the price belongs where
    /// the choice is made.
    @Test("Both cloud providers are offered, with their price and their key link")
    @MainActor
    func providerCardsCarryPriceAndLink() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let cards = panel.contentView?.allDescendants.compactMap { $0 as? ChoiceCard } ?? []

        let assembly = try #require(cards.first { $0.id == "assemblyai" })
        let openai = try #require(cards.first { $0.id == "openai" })

        for card in [assembly, openai] {
            let detail = card.allDescendants
                .compactMap { $0 as? NSTextField }
                .map(\.stringValue)
                .joined(separator: " ")
            #expect(detail.contains("an hour"), "\(card.id) doesn't say what it costs")
        }

        let links = [assembly, openai].compactMap { card in
            card.allDescendants
                .compactMap { $0 as? NSButton }
                .first { $0.title.hasPrefix("Get a key") }?
                .identifier?.rawValue
        }
        #expect(links.contains("https://www.assemblyai.com/dashboard/signup"))
        #expect(links.contains("https://platform.openai.com/api-keys"))
    }

    /// Return in a key field must not reach the window's default button.
    ///
    /// It did, and Done closed the window on the keystroke that submitted the
    /// key — so the check finished into a window nobody could see, and the
    /// person who pasted a key never learned whether it was accepted. Found by
    /// pasting a deliberately wrong key into the built application.
    @Test("Return commits a key field instead of pressing Done")
    @MainActor
    func returnInAKeyFieldIsSwallowed() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let keyFields = panel.contentView?.allDescendants
            .compactMap { $0 as? NSSecureTextField } ?? []
        // Both of them: the cloud key and the summary key sit under the same
        // default button and had the same problem.
        #expect(keyFields.count == 2)

        let editor = NSTextView()
        for field in keyFields {
            let delegate = try #require(field.delegate)
            let swallowed = delegate.control?(
                field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            #expect(swallowed == true, "Return still reaches the default button")

            // Everything else is left alone — Tab still moves on, and Return
            // outside these fields still means Done.
            let tab = delegate.control?(
                field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:)))
            #expect(tab != true)
        }
    }

    @Test("The Summaries switch sits to the left of its heading")
    @MainActor
    func summariesSwitchIsFirst() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let heading = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Summaries" })
        let header = try #require(heading.superview as? NSStackView)

        #expect(header.arrangedSubviews.first is NSSwitch)
    }

    @Test("The Summaries switch is connected to something")
    @MainActor
    func summariesSwitchIsWired() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let heading = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Summaries" })
        let header = try #require(heading.superview as? NSStackView)
        let toggle = try #require(header.arrangedSubviews.first as? NSSwitch)

        // An NSSwitch slides under the finger whether or not anyone is
        // listening, so "it moved" is not evidence that it did anything. This
        // asks the only question that separates the two.
        #expect(toggle.target != nil)
        #expect(toggle.action != nil)
    }

    /// The window used to ask for a two-letter code in a text field, which
    /// nobody could answer from the window and which accepted anything typed
    /// into it. What replaced it has to keep the code out of sight and the
    /// five spoken languages within reach.
    @Test("The meeting language is chosen from a menu of named languages")
    @MainActor
    func languageIsAMenuOfNames() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let label = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Meetings are mostly in" })
        let row = try #require(label.superview as? NSStackView)
        let popup = try #require(row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)

        #expect(popup.target != nil)
        #expect(popup.action != nil)
        #expect(popup.itemTitles.first == "Detect automatically")

        let codes = popup.menu?.items.compactMap { $0.representedObject as? String } ?? []
        #expect(Array(codes.prefix(5)) == MeetingLanguages.pinned)
        #expect(codes.count == MeetingLanguages.menu.count)
        #expect(popup.itemTitles.contains("Русский"))
        #expect(!popup.itemTitles.contains("ru"))
    }

    @Test("Ollama is a full summary card with the official install link")
    @MainActor
    func ollamaIsInstallableChoiceCard() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let ollama = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? ChoiceCard }
            .first { $0.id == "ollama" })
        // The visible label carries a link arrow; the destination is what
        // this test is actually about.
        let install = try #require(ollama.allDescendants
            .compactMap { $0 as? NSButton }
            .first { $0.title.hasPrefix("Install Ollama") })

        #expect(install.identifier?.rawValue == "https://ollama.com/download/mac")
    }

    /// The settings window is not allowed a second, poorer copy of the setup
    /// form: two hand-written forms over one set of settings drift the moment
    /// either is edited. This is the cheapest way to notice — the provider
    /// cards only exist in `SetupForm`, so finding one inside the settings
    /// window is evidence that the window shows the form rather than
    /// imitating it.
    @Test("The settings window shows the setup form itself")
    @MainActor
    func settingsReusesTheSetupForm() throws {
        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu settings" })
        let tabs = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTabView }.first)

        #expect(tabs.tabViewItems.map(\.label) == ["Setup", "Advanced"])
        // Only the selected tab is in the hierarchy, and setup is the one a
        // person opening settings should land on.
        let cards = panel.contentView?.allDescendants.compactMap { $0 as? ChoiceCard } ?? []
        #expect(cards.contains { $0.id == "assemblyai" })
        #expect(cards.contains { $0.id == "claude-cli" })
    }

    /// Setup is a window and also the first tab of Settings, and nothing
    /// stops both being open: the menu opens either, `amanu setup` rings the
    /// doorbell for the window, and the first run opens it by itself.
    ///
    /// Whichever one is used, the other has to agree. It did not: the file
    /// was written correctly and the window nobody had touched kept the old
    /// answer until it was closed and reopened — which reads as the change
    /// not having been saved, and is the reason to look at the file to find
    /// out what a program thinks.
    ///
    /// This is the listening half. That a write announces itself is not
    /// tested here, because `Config.update` writes to the config file of
    /// whoever is running the suite; the manual checklist covers the two
    /// halves together.
    @Test("A config change redraws every open copy of the form")
    @MainActor
    func everyOpenFormRedrawsOnAChange() throws {
        let setup = SetupWindow()
        let settings = SettingsWindow()
        defer { withExtendedLifetime((setup, settings)) {} }

        let panels = [
            try #require(NSApp.windows.last { $0.title == "amanu setup" }),
            try #require(NSApp.windows.last { $0.title == "amanu settings" }),
        ]
        // One switch, in two windows: the settings copy is on its Setup tab,
        // which is the tab a person lands on.
        let switches = try panels.map { panel in
            let label = try #require(panel.contentView?.allDescendants
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "Keep the audio after transcribing" })
            let row = try #require(label.superview?.superview as? NSStackView)
            return try #require(row.arrangedSubviews.compactMap { $0 as? NSSwitch }.first)
        }

        // Both are made to lie, by hand: setting the state fires no action,
        // so nothing is written and the config file is only read here.
        let stored: NSControl.StateValue = Config.keepAudio() ? .on : .off
        for toggle in switches { toggle.state = stored == .on ? .off : .on }

        NotificationCenter.default.post(name: Config.didChange, object: nil)

        for (panel, toggle) in zip(panels, switches) {
            #expect(toggle.state == stored, "\(panel.title) kept the stale answer")
        }
    }

    /// The rule these windows now live by: drawing is not deciding.
    ///
    /// It is not tidiness. Every write announces itself so that each open copy
    /// of the form redraws, so a write from inside a redraw is a loop, not a
    /// wasted syscall — and short of that, the file's timestamp is the only
    /// evidence anybody has that a setting was changed. It was moving on its
    /// own: switching to the Setup tab rewrote the file byte for byte.
    ///
    /// Redrawing is what a config change causes, so posting the change is how
    /// a redraw is asked for here. The count is of the posts this test made
    /// itself; anything above that came from a redraw that wrote.
    @Test("Redrawing every open form leaves the config file alone")
    @MainActor
    func redrawingWritesNothing() throws {
        let setup = SetupWindow()
        let settings = SettingsWindow()
        defer { withExtendedLifetime((setup, settings)) {} }

        let path = Config.path
        let before = try? Data(contentsOf: path)
        let stamped = { (try? FileManager.default.attributesOfItem(atPath: path.path))?
            .first { $0.key == .modificationDate }?.value as? Date }
        let stamp = stamped()

        let posts = PostCount()
        let observer = NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        for _ in 0..<5 {
            NotificationCenter.default.post(name: Config.didChange, object: nil)
        }

        #expect(posts.value == 5, "a redraw wrote the config, and the write announced itself")
        #expect((try? Data(contentsOf: path)) == before, "a redraw changed the config file")
        #expect(stamped() == stamp, "a redraw rewrote the config file with the same bytes")
    }

    /// The bug itself, in the shape it actually happened in.
    ///
    /// Editing ends when a field loses focus, and a field loses focus for
    /// reasons that are nobody's decision — the tab changed, another window
    /// came forward, the window closed. Every one of those committed the row,
    /// which wrote the file back exactly as it already was: `diff` said the
    /// bytes were identical and the timestamp said somebody had just changed
    /// a setting.
    @Test("Leaving an untouched Advanced field writes nothing")
    @MainActor
    func endingEditingOnAnUntouchedRowWritesNothing() throws {
        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu settings" })

        // The Advanced tab is built with the window but only installed in the
        // hierarchy while it is the one on screen, so it is reached through
        // the tab item rather than from the content view.
        let tabs = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTabView }.first)
        let advanced = try #require(tabs.tabViewItems
            .first { $0.identifier as? String == "Advanced" }?.view)
        let fields = advanced.allDescendants
            .compactMap { $0 as? NSTextField }
            .filter { $0.isEditable }
        #expect(!fields.isEmpty, "no editable rows found under Advanced")

        let path = Config.path
        let before = try? Data(contentsOf: path)
        let stamped = { (try? FileManager.default.attributesOfItem(atPath: path.path))?
            .first { $0.key == .modificationDate }?.value as? Date }
        let stamp = stamped()

        for field in fields {
            settings.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field))
        }

        #expect((try? Data(contentsOf: path)) == before, "leaving a field changed the config")
        #expect(stamped() == stamp, "leaving a field rewrote the config with the same bytes")
    }

    /// The wizard answers "what is left?" in one line above its buttons. The
    /// settings tab shows the same form and used to answer it only by being
    /// read row by row — so the line moved to where the form is, both times.
    @Test("The Setup tab says what is outstanding, in the wizard's own words")
    @MainActor
    func setupTabCarriesTheOutstandingLine() throws {
        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }

        #expect(settings.outstandingLine == SetupForm().outstandingSentence)
        #expect(!settings.outstandingLine.isEmpty)
    }

    /// And it has to follow. A grant given in this very window, a switch
    /// thrown in the other one, a model that finished downloading — the form
    /// redraws for all of them, and a line that does not redraw with it is
    /// the same defect one level up.
    @Test("The outstanding line is redrawn whenever the form is")
    @MainActor
    func outstandingLineFollowsTheForm() throws {
        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu settings" })

        let truth = settings.outstandingLine
        let label = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == truth })
        label.stringValue = "something that is not true"

        NotificationCenter.default.post(name: Config.didChange, object: nil)

        #expect(settings.outstandingLine == truth)
    }

    /// Both halves of the sentence matter. Somebody opens that tab to be
    /// reassured at least as often as to repair something, and a line that
    /// only appears when something is wrong leaves them counting green ticks.
    @Test("The sentence says the good news as well as the bad")
    func outstandingSentenceShapes() {
        #expect(SetupForm.sentence(for: []) == "Everything amanu needs is granted.")
        #expect(SetupForm.sentence(for: [.microphone]) == "One thing left: microphone")
        #expect(SetupForm.sentence(for: [.microphone, .systemAudio])
            == "Left: microphone, system audio")
    }

    @Test("The Claude card keeps the automatic fallback chain")
    func summaryChoiceMapping() {
        #expect(SetupSelection.summaryBackend(
            choice: "claude-cli", keyBackend: "anthropic-api") == nil)
        #expect(SetupSelection.summaryBackend(
            choice: "codex-cli", keyBackend: "anthropic-api") == "codex-cli")
        #expect(SetupSelection.summaryBackend(
            choice: "api-key", keyBackend: "openai-api") == "openai-api")
        #expect(SetupSelection.summaryChoice(backend: "auto") == "claude-cli")
    }

    @Test("Summary key probes use each provider's authenticated models endpoint")
    func summaryKeyProbeRequests() {
        let anthropic = SummaryKeyProbe.request(provider: .anthropic, key: "anthropic-secret")
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(anthropic.httpMethod == "GET")
        #expect(anthropic.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let openAI = SummaryKeyProbe.request(provider: .openAI, key: "openai-secret")
        #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(openAI.httpMethod == "GET")
        #expect(openAI.value(forHTTPHeaderField: "authorization") == "Bearer openai-secret")
    }

    @Test("Ordinary links start visible; availability detection may hide install links")
    @MainActor
    func choiceCardLinkVisibility() {
        let link = NSButton(title: "Get a key", target: nil, action: nil)
        link.bezelStyle = .inline
        let card = ChoiceCard(
            id: "key", title: "My key", detail: "API", accessories: [link])

        #expect(!link.isHidden)
        card.showLink(false)
        #expect(link.isHidden)
        card.showLink(true)
        #expect(!link.isHidden)
    }

    @Test("A card's border is re-read when the Mac changes appearance")
    @MainActor
    func cardBorderFollowsAppearance() throws {
        // The bug this is about: a CGColor is a number, so a border read from
        // `separatorColor` under one appearance stays that number under the
        // other, where it is invisible. The window lost every border and
        // hairline the first time someone switched their Mac while it was
        // open.
        let card = ChoiceCard(id: "one", title: "One", detail: "The first")

        card.appearance = NSAppearance(named: .darkAqua)
        #expect(card.layer?.borderColor == separator(0.6, in: .darkAqua))
        card.appearance = NSAppearance(named: .aqua)
        #expect(card.layer?.borderColor == separator(0.6, in: .aqua))

        // The chosen card is the accent colour instead, and follows too.
        card.isSelected = true
        #expect(card.layer?.borderColor != separator(0.6, in: .aqua))
        card.appearance = NSAppearance(named: .darkAqua)
        card.isSelected = false
        #expect(card.layer?.borderColor == separator(0.6, in: .darkAqua))
    }

    @Test("A box and its hairlines are re-read when the Mac changes appearance")
    @MainActor
    func boxBorderFollowsAppearance() throws {
        let box = SetupLayout.box([SetupLayout.title("First"), SetupLayout.title("Second")])
        let hairline = try #require(box.subviews.compactMap { $0 as? Hairline }.first)

        box.appearance = NSAppearance(named: .darkAqua)
        #expect(box.layer?.borderColor == separator(in: .darkAqua))
        #expect(hairline.layer?.backgroundColor == separator(in: .darkAqua))

        box.appearance = NSAppearance(named: .aqua)
        #expect(box.layer?.borderColor == separator(in: .aqua))
        #expect(hairline.layer?.backgroundColor == separator(in: .aqua))
    }

    /// What `separatorColor` comes to under a named appearance — the value a
    /// correctly tinted layer should be holding.
    @MainActor
    private func separator(_ alpha: CGFloat? = nil, in name: NSAppearance.Name) -> CGColor? {
        var resolved: CGColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            let colour = NSColor.separatorColor
            resolved = (alpha.map(colour.withAlphaComponent) ?? colour).cgColor
        }
        return resolved
    }

    @Test("Doctor accepts either API key or a CLI that actually runs")
    func summaryAvailabilityPolicy() {
        #expect(DoctorReport.hasSummaryBackend(
            anthropicKey: nil, openAIKey: "key", claudeRuns: false, codexRuns: false))
        #expect(DoctorReport.hasSummaryBackend(
            anthropicKey: nil, openAIKey: nil, claudeRuns: false, codexRuns: true))
        #expect(!DoctorReport.hasSummaryBackend(
            anthropicKey: nil, openAIKey: nil, claudeRuns: false, codexRuns: false))
    }
}

private extension NSView {
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}

/// A counter the notification centre can reach from inside its closure. Posts
/// are delivered synchronously on the thread that made them, so there is no
/// race here to protect against — the box is for the compiler.
private final class PostCount: @unchecked Sendable {
    var value = 0
}
