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
        card.status = "answers · 1.0"

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

    @Test("The Keep Audio label is the checkbox's clickable title")
    @MainActor
    func keepAudioUsesTitledCheckbox() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let checkbox = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Keep the audio after transcribing" })

        checkbox.target = nil
        checkbox.action = nil
        checkbox.state = .off
        checkbox.performClick(nil)

        #expect(checkbox.state == .on)
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
