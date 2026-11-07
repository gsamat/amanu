import AppKit
import Foundation
import Testing
import os

@testable import amanu

@Suite(.serialized, .freshHome)
@MainActor
struct CompatibleTranscriptionSettingsTests {
    private func field<T: NSView>(_ id: String, in form: SetupForm, as: T.Type = T.self) throws -> T {
        try #require(form.view.allDescendants.first { $0.identifier?.rawValue == id } as? T)
    }

    @Test("Compatible server settings round-trip without becoming auto or borrowing credentials")
    func configurationAndTokenIsolation() throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "base_url": "https://speech.example/v1", "model": "private-speech", "protocol": "mlx-audio",
        ]]])
        try Credentials.writeSecret("openai-secret", to: Config.openAIKeyPath)
        try Credentials.writeSecret("summary-secret", to: Credentials.openAICompatibleKeyPath)
        #expect(Config.compatibleTranscriptionKey() == nil)
        let form = SetupForm()
        let toggle: NSButton = try field("transcription.compatible", in: form)
        #expect(toggle.state == .on)
        #expect(Config.compatibleTranscriptionBaseURL() == "https://speech.example/v1")
        #expect(Config.compatibleTranscriptionModel() == "private-speech")
        #expect(Config.compatibleTranscriptionProtocol() == "mlx-audio")
        let token: NSSecureTextField = try field("transcription.compatible.token", in: form)
        token.stringValue = "speech-secret"
        form.reload()
        #expect(token.stringValue == "speech-secret", "refresh must not discard a token being edited")
        #expect(Config.compatibleTranscriptionKey() == nil, "refresh must not save an unfinished token")
        form.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: token))
        #expect(Config.compatibleTranscriptionKey() == "speech-secret")
        let tokenStatus: NSTextField = try field("transcription.compatible.token-status", in: form)
        let remove: NSButton = try field("transcription.compatible.remove-token", in: form)
        #expect(!tokenStatus.stringValue.isEmpty && !remove.isHidden)
        #expect(Config.openAIKey() == "openai-secret")
        #expect(Config.secret(at: Credentials.openAICompatibleKeyPath) == "summary-secret")
        #expect(!(Home.current.configText ?? "").contains("speech-secret"))
        remove.performClick(nil)
        #expect(Config.compatibleTranscriptionKey() == nil)
        #expect(remove.isHidden)
        #expect(Config.openAIKey() == "openai-secret")
        form.reload()
        #expect(Config.transcriptionEngine() == "compatible")
        #expect(toggle.state == .on)
        form.stop()
    }

    @Test("A compatible token path outside Amanu is read but never overwritten by Setup")
    func namedTokenPathIsReadOnly() throws {
        let other = Home.current.url.appendingPathComponent("shared-secret")
        try Credentials.writeSecret("original", to: other)
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "api_key_path": other.path,
        ]]])
        let form = SetupForm()
        let token: NSSecureTextField = try field("transcription.compatible.token", in: form)
        let remove: NSButton = try field("transcription.compatible.remove-token", in: form)
        #expect(remove.isHidden, "a token owned by another application must not be removed")
        token.stringValue = "replacement"
        form.saveCompatibleToken()
        #expect(Config.compatibleTranscriptionKey() == "original")
        #expect(Config.secret(at: other) == "original")
        form.stop()
    }

    @Test("Changing the cloud provider in automatic mode preserves its local fallback",
          .enabled(if: Platform.supportsLocalModels))
    func changingProviderKeepsFallback() throws {
        try Home.current.writeConfig(["transcription": ["engine": "auto"]])
        let slot = Credentials.transcriptionSlot(for: "openai", in: Config.raw())
        try Credentials.writeSecret("fixture-key", to: slot.path)
        let form = SetupForm()
        defer { form.stop() }
        let card = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "openai" })
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        card.mouseDown(with: event)
        #expect(Config.transcriptionEngine() == "auto")
        #expect(Config.transcriptionCloudProvider() == "openai")
        let modes: NSPopUpButton = try field("transcription.additional-modes", in: form)
        #expect(modes.selectedItem?.representedObject as? String == "auto")
        let gigaam = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "gigaam" })
        gigaam.mouseDown(with: event)
        #expect(Config.transcriptionEngine() == "auto")
        #expect(Config.transcriptionLocalEngine() == "gigaam")
        #expect(modes.selectedItem?.representedObject as? String == "auto")
    }

    @Test("Changing a provider while selecting cloud-only never restores the old fallback",
          .enabled(if: Platform.supportsLocalModels), arguments: [false, true])
    func pendingCloudOnlySurvivesProviderChange(alreadySaved: Bool) async throws {
        try Home.current.writeConfig(["transcription": ["engine": "auto"]])
        if alreadySaved {
            let slot = Credentials.transcriptionSlot(for: "openai", in: Config.raw())
            try Credentials.writeSecret("fixture-key", to: slot.path)
        }
        let form = SetupForm()
        defer { form.stop() }
        form.checkKey = { _ in .works }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        cloud.performClick(nil) // AssemblyAI needs a key; auto stays in force.
        #expect(Config.transcriptionEngine() == "auto")
        let card = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "openai" })
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        card.mouseDown(with: event)
        if !alreadySaved {
            #expect(Config.transcriptionEngine() == "auto", "keep the old engine until the key works")
            let key: NSSecureTextField = try field("transcription.key", in: form)
            key.stringValue = "fixture-key"
            await form.saveCloudKey()
        }
        #expect(Config.transcriptionEngine() == "openai")
        #expect(cloud.state == .on)
        let local: NSView = try field("transcription.local-options", in: form)
        #expect(local.isHidden, "an explicit cloud choice must not keep a local fallback")
    }

    @Test("Only the selected transcription mode shows its options, including a pending cloud key",
          .enabled(if: Platform.supportsLocalModels))
    func optionsFollowSelection() throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        let local: NSView = try field("transcription.local-options", in: form)
        let cloud: NSView = try field("transcription.cloud-options", in: form)
        let serverURL: NSTextField = try field("transcription.compatible.base-url", in: form)
        let cloudKey: NSTextField = try field("transcription.key", in: form)
        #expect(local.isHidden && cloud.isHidden)
        #expect(!serverURL.isHiddenOrHasHiddenAncestor)

        let cloudMode: NSButton = try field("transcription.cloud", in: form)
        cloudMode.performClick(nil)
        #expect(Config.transcriptionEngine() == "compatible", "missing cloud key must keep the previous mode")
        #expect(!cloud.isHidden && !cloudKey.isHiddenOrHasHiddenAncestor)
        #expect(local.isHidden && !serverURL.isHiddenOrHasHiddenAncestor)

        let localMode: NSButton = try field("transcription.local", in: form)
        localMode.performClick(nil)
        #expect(!local.isHidden && cloud.isHidden)
        #expect(serverURL.isHiddenOrHasHiddenAncestor)

        let modes: NSPopUpButton = try field("transcription.additional-modes", in: form)
        modes.selectItem(at: 1)
        modes.sendAction(modes.action, to: modes.target)
        #expect(!local.isHidden && !cloud.isHidden, "automatic mode must show both fallback options")
        #expect(serverURL.isHiddenOrHasHiddenAncestor)
    }

    @Test("The server check runs recognition and exposes its real result")
    func serverCheck() async throws {
        let form = SetupForm()
        var connection = 0
        var recognition = 0
        form.checkCompatibleConnection = { connection += 1; return "server answered" }
        form.checkCompatibleRecognition = { recognition += 1; return "public phrase recognized" }
        let status: NSTextField = try field("transcription.compatible.status", in: form)
        let button: NSButton = try field("transcription.compatible.check-recognition", in: form)
        button.performClick(nil)
        await form.waitForCompatibleCheck()
        #expect(connection == 0 && recognition == 1)
        #expect(status.stringValue == "public phrase recognized")
        form.stop()
    }

    @Test("Connection probing sends no audio and distinguishes HTTP response from authentication")
    func connectionProbeHasNoMeetingPayload() async throws {
        let methods = OSAllocatedUnfairLock(initialState: [String]())
        let session = StubbedService.session { request in
            #expect(request.httpBody == nil && request.httpBodyStream == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer speech-token")
            methods.withLock { $0.append(request.httpMethod ?? "") }
            return .success(request.httpMethod == "HEAD" ? 405 : 404)
        }
        let result = try await CompatibleTranscriptionProbe.connection(
            baseURL: "http://127.0.0.1:8000/v1", token: "speech-token", session: session)
        #expect(result.contains("404"))
        #expect(methods.withLock { $0 } == ["HEAD", "GET"])
        let refused = StubbedService.session { _ in .success(401) }
        await #expect(throws: CompatibleTranscriptionProbe.Failure.self) {
            _ = try await CompatibleTranscriptionProbe.connection(
                baseURL: "https://speech.example/v1", token: "wrong", session: refused)
        }
    }

    @Test("Failure to synthesize public speech sends nothing and removes its temporary directory")
    func failedSynthesisNeverUsesMeetingAudio() async {
        let generated = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let sent = OSAllocatedUnfairLock(initialState: false)
        let session = StubbedService.session { _ in sent.withLock { $0 = true }; return .success(200) }
        do {
            _ = try await CompatibleTranscriptionProbe.recognition(
                baseURL: "http://localhost:8000/v1", model: "test", token: nil,
                apiProtocol: "mlx-audio", session: session,
                synthesize: { url in
                    generated.withLock { $0 = url }
                    throw CompatibleTranscriptionProbe.Failure.speechFailed
                })
            Issue.record("Synthesis should have failed")
        } catch { }
        #expect(!sent.withLock { $0 })
        if let url = generated.withLock({ $0 }) {
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        } else { Issue.record("The public fixture path was not requested") }
    }
}
