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

    @Test("Turning transcription off and on preserves the chosen engine and fallback model",
          arguments: ["compatible", "parakeet", "auto", "openai"])
    func enabledSwitchPreservesEngine(engine: String) throws {
        try Home.current.writeConfig(["transcription": ["engine": engine, "local_engine": "gigaam"]])
        let form = SetupForm()
        defer { form.stop() }
        let toggle: NSSwitch = try field("transcription.enabled", in: form)
        let choices: NSView = try field("transcription.choices", in: form)
        #expect(toggle.state == .on && !choices.isHidden)
        toggle.performClick(nil)
        #expect(!Config.transcriptionEnabled())
        #expect(Config.transcriptionEngine() == engine)
        #expect(Config.transcriptionLocalEngine() == "gigaam")
        #expect(choices.isHidden)
        form.reload()
        #expect(!Config.transcriptionEnabled() && Config.transcriptionEngine() == engine)
        toggle.performClick(nil)
        #expect(Config.transcriptionEnabled() && Config.transcriptionEngine() == engine)
        #expect(Config.transcriptionLocalEngine() == "gigaam")
        #expect(!choices.isHidden)
    }

    @Test("A pending cloud choice keeps its fallback until a key is accepted",
          .enabled(if: Platform.supportsLocalModels))
    func pendingCloudFallbackSurvivesKeyCheck() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "local_engine": "gigaam"]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        form.checkKey = { _ in .works }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let fallback: NSSwitch = try field("transcription.cloud-fallback", in: form)
        let model: NSPopUpButton = try field("transcription.cloud-fallback-model", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        fallback.performClick(nil)
        #expect(Config.transcriptionEngine() == "compatible", "the old engine remains active until the key is checked")
        #expect(fallback.state == .on && !model.isHiddenOrHasHiddenAncestor)
        model.selectItem(at: 0)
        model.sendAction(model.action, to: model.target)
        #expect(Config.transcriptionLocalEngine() == "gigaam", "pending choices must not change the active configuration")
        key.stringValue = "fixture-key"
        await form.saveCloudKey()
        #expect(Config.transcriptionEngine() == "auto")
        #expect(Config.transcriptionLocalEngine() == "parakeet")
        #expect(fallback.state == .on && cloud.state == .on)
    }

    @Test("Confirming a pending cloud fallback downloads its model and exposes errors",
          .enabled(if: Platform.supportsLocalModels), arguments: [false, true])
    func confirmingPendingFallbackDownloadsModel(alreadySaved: Bool) async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        if alreadySaved {
            let slot = Credentials.transcriptionSlot(for: "openai", in: Config.raw())
            try Credentials.writeSecret("fixture-key", to: slot.path)
        }
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { false }
        form.checkKey = { _ in .works }
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finishDownload: CheckedContinuation<Void, Error>?
        form.fetchParakeet = {
            try await withCheckedThrowingContinuation { continuation in
                finishDownload = continuation
                signal.yield()
            }
        }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let fallback: NSSwitch = try field("transcription.cloud-fallback", in: form)
        let status: NSTextField = try field("transcription.cloud-fallback-status", in: form)
        let retry: NSButton = try field("transcription.cloud-fallback-download", in: form)
        cloud.performClick(nil)
        fallback.performClick(nil)
        #expect(Config.transcriptionEngine() == "compatible")
        if alreadySaved {
            let card = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
                .first { $0.id == "openai" })
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            card.mouseDown(with: event)
        } else {
            let key: NSSecureTextField = try field("transcription.key", in: form)
            key.stringValue = "fixture-key"
            await form.saveCloudKey()
        }
        #expect(Config.transcriptionEngine() == "auto")
        for await _ in started { break }
        #expect(form.isDownloading)
        #expect(!status.isHiddenOrHasHiddenAncestor && !status.stringValue.isEmpty)
        #expect(retry.isHidden, "the retry button must not start a second download")
        struct FixtureFailure: Error {}
        try #require(finishDownload).resume(throwing: FixtureFailure())
        for _ in 0..<1_000 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(status.textColor == .systemOrange, "the failure must be visible next to the fallback")
        #expect(!retry.isHiddenOrHasHiddenAncestor, "a failed download must be retryable")
        signal.finish()
    }

    @Test("Selecting a compatible server explicitly uses MLX Audio for custom domains")
    func compatibleServerUsesMLXForCustomDomain() throws {
        try Home.current.writeConfig(["transcription": ["engine": "parakeet", "compatible": [
            "base_url": "https://speech.example/prefix/v1", "model": "speech-model",
        ]]])
        let form = SetupForm()
        defer { form.stop() }
        #expect(Config.compatibleTranscriptionProtocol() == "auto", "opening settings must not migrate config")
        let compatible: NSButton = try field("transcription.compatible", in: form)
        compatible.performClick(nil)
        #expect(Config.transcriptionEngine() == "compatible")
        #expect(Config.compatibleTranscriptionProtocol() == "mlx-audio")
        let label: NSTextField = try field("transcription.compatible.format", in: form)
        #expect(label.stringValue.contains("MLX Audio"))
        let resolved = try CompatibleTranscriptionEngine.resolve(
            baseURL: Config.compatibleTranscriptionBaseURL(), protocol: .mlxAudio,
            model: Config.compatibleTranscriptionModel())
        #expect(resolved.endpoint.absoluteString == "https://speech.example/prefix/v1/audio/transcriptions")
    }

    @Test("Legacy server profiles remain unchanged until explicitly switched",
          arguments: [("deepinfra", "https://example.com/v1", "DeepInfra"),
                      ("openrouter", "https://example.com/v1", "OpenRouter"),
                      ("auto", "https://api.deepinfra.com/v1", "DeepInfra"),
                      ("auto", "https://openrouter.ai/api/v1", "OpenRouter")])
    func legacyCompatibleProfilesStayVisible(profile: String, baseURL: String, display: String) throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "base_url": baseURL, "model": "speech-model", "protocol": profile,
        ]]])
        let form = SetupForm()
        defer { form.stop() }
        let label: NSTextField = try field("transcription.compatible.format", in: form)
        let change: NSButton = try field("transcription.compatible.use-mlx", in: form)
        #expect(label.stringValue.contains(display))
        #expect(!change.isHiddenOrHasHiddenAncestor)
        #expect(Config.compatibleTranscriptionProtocol() == profile)
        form.reload()
        #expect(Config.compatibleTranscriptionProtocol() == profile)
        let model: NSTextField = try field("transcription.compatible.model", in: form)
        model.stringValue = "updated-model"
        form.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: model))
        #expect(Config.compatibleTranscriptionProtocol() == profile, "editing a legacy model must not silently switch APIs")
        #expect(label.stringValue.contains(display))
        change.performClick(nil)
        #expect(Config.compatibleTranscriptionProtocol() == "mlx-audio")
        #expect(label.stringValue.contains("MLX Audio"))
        #expect(change.isHiddenOrHasHiddenAncestor)
    }

    @Test("Editing a server address fixes the MLX profile regardless of the new host",
          arguments: ["http://127.0.0.1:8001/v1", "https://old.example/v1"])
    func editedServerAddressUsesMLX(previousAddress: String) throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible", "compatible": [
            "base_url": previousAddress, "protocol": "auto",
        ]]])
        let form = SetupForm()
        defer { form.stop() }
        let label: NSTextField = try field("transcription.compatible.format", in: form)
        #expect(Config.compatibleTranscriptionProtocol() == "auto", "opening does not change the profile")
        let address: NSTextField = try field("transcription.compatible.base-url", in: form)
        address.stringValue = "https://api.deepinfra.com/custom/v1"
        form.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: address))
        #expect(Config.compatibleTranscriptionProtocol() == "mlx-audio")
        #expect(Config.compatibleTranscriptionBaseURL() == "https://api.deepinfra.com/custom/v1")
        #expect(label.stringValue.contains("MLX Audio"))
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
        form.parakeetIsHere = { true }
        let card = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "openai" })
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        card.mouseDown(with: event)
        #expect(Config.transcriptionEngine() == "auto")
        #expect(Config.transcriptionCloudProvider() == "openai")
        let fallback: NSSwitch = try field("transcription.cloud-fallback", in: form)
        #expect(fallback.state == .on)
        #expect(Config.transcriptionLocalEngine() == "parakeet")
        let model: NSPopUpButton = try field("transcription.cloud-fallback-model", in: form)
        model.selectItem(at: 0)
        model.sendAction(model.action, to: model.target)
        #expect(Config.transcriptionEngine() == "auto")
        #expect(Config.transcriptionLocalEngine() == "parakeet")
        #expect(fallback.state == .on)
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
        let fallback: NSSwitch = try field("transcription.cloud-fallback", in: form)
        fallback.performClick(nil) // AssemblyAI needs a key; auto stays in force.
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
        #expect(local.isHidden && serverURL.isHiddenOrHasHiddenAncestor)

        let localMode: NSButton = try field("transcription.local", in: form)
        localMode.performClick(nil)
        #expect(!local.isHidden && cloud.isHidden)
        #expect(serverURL.isHiddenOrHasHiddenAncestor)

        try Home.current.writeConfig(["transcription": ["engine": "auto"]])
        form.reload()
        let fallback: NSSwitch = try field("transcription.cloud-fallback", in: form)
        #expect(local.isHidden && !cloud.isHidden, "fallback appears inside cloud, not as a second mode")
        #expect(fallback.state == .on)
        #expect(serverURL.isHiddenOrHasHiddenAncestor)
    }

    @Test("Choosing cloud without a key shows only the requested mode without changing the working engine",
          .enabled(if: Platform.supportsLocalModels), arguments: ["parakeet", "compatible"])
    func pendingCloudShowsTheSelectedMode(startingEngine: String) async throws {
        try Home.current.writeConfig(["transcription": ["engine": startingEngine]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        form.checkKey = { _ in .refused }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let local: NSButton = try field("transcription.local", in: form)
        let server: NSButton = try field("transcription.compatible", in: form)
        let localOptions: NSView = try field("transcription.local-options", in: form)
        let cloudOptions: NSView = try field("transcription.cloud-options", in: form)
        let serverURL: NSTextField = try field("transcription.compatible.base-url", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)

        cloud.performClick(nil)
        #expect(Config.transcriptionEngine() == startingEngine, "a missing key must not replace the working engine")
        #expect(cloud.state == .on && local.state == .off && server.state == .off,
                "the radio buttons must show the mode being configured")
        #expect(localOptions.isHidden && !cloudOptions.isHidden && serverURL.isHiddenOrHasHiddenAncestor,
                "only cloud settings should be visible")

        form.reload()
        #expect(cloud.state == .on && local.state == .off && server.state == .off,
                "refresh must preserve the pending selection")
        #expect(localOptions.isHidden && !cloudOptions.isHidden && serverURL.isHiddenOrHasHiddenAncestor)

        key.stringValue = "rejected-fixture-key"
        await form.saveCloudKey()
        #expect(Config.transcriptionEngine() == startingEngine, "a refused key must not replace the working engine")
        #expect(cloud.state == .on && local.state == .off && server.state == .off)
        #expect(localOptions.isHidden && !cloudOptions.isHidden && serverURL.isHiddenOrHasHiddenAncestor)

        (startingEngine == "parakeet" ? local : server).performClick(nil)
        #expect(Config.transcriptionEngine() == startingEngine)
        #expect(cloud.state == .off && cloudOptions.isHidden)
        #expect(startingEngine == "parakeet" ? local.state == .on : server.state == .on)
    }

    @Test("A config change from another isolated home cannot cancel this form's pending choice",
          .enabled(if: Platform.supportsLocalModels))
    func unrelatedHomeNotificationPreservesPendingChoice() throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let otherHome = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: otherHome.url) }
        try otherHome.writeConfig(["transcription": ["engine": "parakeet"]])
        let form = SetupForm()
        defer { form.stop() }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let local: NSButton = try field("transcription.local", in: form)
        let server: NSButton = try field("transcription.compatible", in: form)
        let cloudOptions: NSView = try field("transcription.cloud-options", in: form)
        let serverURL: NSTextField = try field("transcription.compatible.base-url", in: form)
        cloud.performClick(nil)
        #expect(Config.transcriptionEngine() == "compatible")
        #expect(cloud.state == .on && local.state == .off && server.state == .off)

        Home.$scoped.withValue(otherHome) {
            NotificationCenter.default.post(name: Config.didChange, object: nil)
        }
        #expect(Config.transcriptionEngine() == "compatible")
        #expect(cloud.state == .on && local.state == .off && server.state == .off,
                "a notification must redraw using the form's own home")
        #expect(!cloudOptions.isHidden && serverURL.isHiddenOrHasHiddenAncestor)

        Config.update(path: ["transcription", "engine"], value: "parakeet")
        #expect(local.state == .on && cloud.state == .off && server.state == .off,
                "a genuine change in the form's own home must still redraw it")
    }

    @Test("A late cloud key check cannot replace a mode selected while it was in flight",
          .enabled(if: Platform.supportsLocalModels))
    func cloudKeyCheckDoesNotOverrideLaterModeSelection() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finishCheck: CheckedContinuation<Credentials.Verdict, Never>?
        form.checkKey = { _ in
            await withCheckedContinuation { continuation in
                finishCheck = continuation
                signal.yield()
            }
        }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let local: NSButton = try field("transcription.local", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        key.stringValue = "fixture-key"
        let check = Task { await form.saveCloudKey() }
        for await _ in started { break }
        local.performClick(nil)
        #expect(Config.transcriptionEngine() == "parakeet")
        try #require(finishCheck).resume(returning: .works)
        await check.value
        #expect(Config.transcriptionEngine() == "parakeet", "a stale check must not switch the engine")
        #expect(local.state == .on && cloud.state == .off)
    }

    @Test("An older key verification cannot overwrite a newer accepted key")
    func olderCloudKeyCheckCannotOverwriteNewerKey() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finishFirst: CheckedContinuation<Credentials.Verdict, Never>?
        form.checkKey = { check in
            if check.key == "old-fixture-key" {
                return await withCheckedContinuation { continuation in
                    finishFirst = continuation
                    signal.yield()
                }
            }
            return .works
        }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        key.stringValue = "old-fixture-key"
        let first = Task { await form.saveCloudKey() }
        for await _ in started { break }
        key.stringValue = "new-fixture-key"
        await form.saveCloudKey()
        try #require(finishFirst).resume(returning: .works)
        await first.value
        let slot = Credentials.transcriptionSlot(for: "assemblyai", in: Config.raw())
        #expect(Config.secret(at: slot.path) == "new-fixture-key", "older validation must not overwrite the new key")
        #expect(Config.transcriptionEngine() == "assemblyai")
    }

    @Test("A key edited while verification runs is not cleared or replaced by the earlier result")
    func keyEditDuringCloudKeyCheckRemainsUnchanged() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finishCheck: CheckedContinuation<Credentials.Verdict, Never>?
        form.checkKey = { _ in
            await withCheckedContinuation { continuation in
                finishCheck = continuation
                signal.yield()
            }
        }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        key.stringValue = "old-fixture-key"
        let check = Task { await form.saveCloudKey() }
        for await _ in started { break }
        key.stringValue = "new-unsubmitted-fixture-key"
        try #require(finishCheck).resume(returning: .works)
        await check.value
        let slot = Credentials.transcriptionSlot(for: "assemblyai", in: Config.raw())
        #expect(key.stringValue == "new-unsubmitted-fixture-key", "a stale response must not clear a newer edit")
        #expect(Config.secret(at: slot.path) == nil, "a stale response must not save the earlier key")
        #expect(Config.transcriptionEngine() == "compatible", "a stale response must not switch engines")
    }

    @Test("A provider changed during key verification stays selected")
    func providerChangeDuringCloudKeyCheck() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        let (started, signal) = AsyncStream<Void>.makeStream()
        var finishFirst: CheckedContinuation<Credentials.Verdict, Never>?
        form.checkKey = { _ in
            await withCheckedContinuation { continuation in
                finishFirst = continuation
                signal.yield()
            }
        }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        key.stringValue = "assembly-fixture-key"
        let first = Task { await form.saveCloudKey() }
        for await _ in started { break }
        let openAI = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "openai" })
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        openAI.mouseDown(with: event)
        try #require(finishFirst).resume(returning: .works)
        await first.value
        #expect(Config.transcriptionEngine() == "compatible", "an earlier provider must not override the new choice")
        #expect(cloud.state == .on, "keep the new provider's pending cloud setup visible")
        #expect(key.placeholderString == "sk-…", "OpenAI must remain the selected provider")
    }

    @Test("A deferred cloud key check never sends a key to the previous provider",
          .enabled(if: Platform.supportsLocalModels))
    func deferredCloudBlurRetainsItsProviderOrIsCancelled() async throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        var checkedServices: [Credentials.Check.Service] = []
        form.checkKey = { check in checkedServices.append(check.service); return .works }
        let cloud: NSButton = try field("transcription.cloud", in: form)
        let local: NSButton = try field("transcription.local", in: form)
        let key: NSSecureTextField = try field("transcription.key", in: form)
        cloud.performClick(nil)
        let openAI = try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "openai" })
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 120, y: 40), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        openAI.mouseDown(with: event)
        key.stringValue = "openai-fixture-key"
        form.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: key))
        local.performClick(nil)
        await Task { @MainActor in }.value
        #expect(checkedServices.allSatisfy { $0 == .openAI(baseURL: "https://api.openai.com/v1") },
                "a key must never be validated with a different provider")
        #expect(Config.transcriptionEngine() == "parakeet", "a deferred check must not undo the new choice")
    }

    @Test("A compatible token is saved when leaving the server mode",
          .enabled(if: Platform.supportsLocalModels))
    func compatibleTokenSurvivesModeSwitch() throws {
        try Home.current.writeConfig(["transcription": ["engine": "compatible"]])
        let form = SetupForm()
        defer { form.stop() }
        form.parakeetIsHere = { true }
        let token: NSSecureTextField = try field("transcription.compatible.token", in: form)
        let local: NSButton = try field("transcription.local", in: form)
        token.stringValue = "compatible-fixture-token"
        form.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: token))
        local.performClick(nil)
        #expect(Config.compatibleTranscriptionKey() == "compatible-fixture-token")
        #expect(Config.transcriptionEngine() == "parakeet")
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
