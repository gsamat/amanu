import ArgumentParser
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

    @Test("First-run setup bypasses a denied microphone, not a broken recordings folder")
    func doctorRepairBoundary() {
        let microphone = Check(name: "microphone", status: .fail("denied"), remediation: nil)
        let recordings = Check(
            name: "recordings folder", status: .fail("not writable"), remediation: nil)

        #expect(DoctorReport.canContinueIntoSetup([microphone]))
        #expect(!DoctorReport.canContinueIntoSetup([microphone, recordings]))
    }

    @Test("Launch setup hands off unless this process is already launchd's copy")
    @MainActor
    func launchAgentHandoffPolicy() {
        #expect(SetupPermissions.needsLaunchAgentHandoff(
            installed: false, runningUnderLaunchd: false))
        #expect(SetupPermissions.needsLaunchAgentHandoff(
            installed: true, runningUnderLaunchd: false))
        #expect(!SetupPermissions.needsLaunchAgentHandoff(
            installed: true, runningUnderLaunchd: true))
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

    @Test("Ollama is a full summary card with the official install link")
    @MainActor
    func ollamaIsInstallableChoiceCard() throws {
        let setup = SetupWindow()
        defer { withExtendedLifetime(setup) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "amanu setup" })
        let ollama = try #require(panel.contentView?.allDescendants
            .compactMap { $0 as? ChoiceCard }
            .first { $0.id == "ollama" })
        let install = try #require(ollama.allDescendants
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Install Ollama" })

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
