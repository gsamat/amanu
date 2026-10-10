import AppKit
import Foundation
import Testing

@testable import amanu

/// What the setup form does when it is used, rather than how it is laid out:
/// clicks that have to write something, work that has to survive the window
/// closing, and things it must refuse to do in the middle of a meeting.
@Suite(.serialized)
@MainActor
struct SetupFormBehaviourTests {
    @Test("Speaker model cards require local transcription and the feature switch",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationSwitchDoesNotDownload() throws {
        let form = SetupForm()
        defer { form.stop() }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let names = ["nemotron-3", "ls-eend-ami", "community-1"]
        let cards = try names.map { try #require(Self.view("choice.diarization.\($0)", in: form) as? ChoiceCard) }
        let downloads = try names.map { try #require(Self.button("transcription.diarization.download.\($0)", in: form)) }
        #expect(toggle.state == .off)
        #expect(cards.map(\.isSelected) == [true, false, false])
        #expect(cards.allSatisfy { !$0.isEnabled })
        #expect(downloads.allSatisfy { !$0.isEnabled })
        toggle.performClick(nil)
        #expect(Config.localDiarizationEnabled())
        #expect(cards.allSatisfy { $0.isEnabled })
        #expect(downloads.allSatisfy { $0.isEnabled }, "enabling the feature started a hidden download")
        #expect(cards[1].accessibilityPerformPress())
        #expect(cards.map(\.isSelected) == [false, true, false])
        #expect(Config.diarizationModel() == .lsEendAMI)
        #expect(Self.labels(in: cards[0]).joined(separator: " ").contains("107 MB"))
        #expect(Self.labels(in: cards[1]).joined(separator: " ").contains("45 MB"))
        #expect(Self.labels(in: cards[2]).joined(separator: " ").contains("21 MB"))
        toggle.performClick(nil)
        #expect(cards.allSatisfy { !$0.isEnabled })
        #expect(Config.diarizationModel() == .lsEendAMI, "turning the feature off lost the selected model")
    }

    @Test("Returning to Nemotron saves an explicit speaker-model preference",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet","local_diarization":true}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationDefaultPickIsPersisted() throws {
        let form = SetupForm()
        defer { form.stop() }
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        #expect(ami.accessibilityPerformPress())
        #expect(nemo.accessibilityPerformPress())
        #expect(Config.diarizationModel() == .nemotron3)
        let saved = try String(contentsOf: Config.path, encoding: .utf8)
        let config = try #require(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        let transcription = try #require(config["transcription"] as? [String: Any])
        #expect(transcription["diarization_model"] as? String == "nemotron-3",
                "an explicit selection must survive a future default change")
    }

    @Test("Cloud-only mode cannot enable speaker separation",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"openai","local_diarization":true}}"#),
          .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func diarizationRequiresLocalMode() throws {
        let form = SetupForm()
        defer { form.stop() }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        #expect(!toggle.isEnabled)
        #expect(!card.isEnabled)
        #expect(!download.isEnabled)
        #expect(!card.accessibilityPerformPress())
        #expect(Self.labels(in: form.view).contains("Available with On this Mac enabled."))
    }

    @Test("A broken config leaves the speaker choices unavailable",
          .freshHome(config: "{broken"), .enabled(if: Platform.supportsLocalModels))
    func diarizationCannotBypassBadConfig() throws {
        let form = Self.localForm()
        defer { form.stop() }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        #expect(!toggle.isEnabled)
        #expect(!card.isEnabled)
        #expect(!card.accessibilityPerformPress())
    }

    @Test("Speaker radio cards explain their capacity in English", .freshHome,
          .speaking(.english))
    func diarizationEnglishDescriptions() throws {
        let form = SetupForm()
        defer { form.stop() }
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let community = try #require(Self.view("choice.diarization.community-1", in: form) as? ChoiceCard)
        #expect(nemo.accessibilityHelp()?.contains("Meetings up to 8 speakers") == true)
        #expect(ami.accessibilityHelp()?.contains("Meetings up to 4 speakers") == true)
        #expect(community.accessibilityHelp()?.contains("Compact alternative") == true)
    }

    @Test("Speaker radio cards explain their capacity in Russian", .freshHome,
          .speaking(.russian))
    func diarizationRussianDescriptions() throws {
        let form = SetupForm()
        defer { form.stop() }
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let community = try #require(Self.view("choice.diarization.community-1", in: form) as? ChoiceCard)
        #expect(nemo.accessibilityHelp()?.contains("Встречи до 8 говорящих") == true)
        #expect(ami.accessibilityHelp()?.contains("Встречи до 4 говорящих") == true)
        #expect(community.accessibilityHelp()?.contains("Компактная альтернатива") == true)
    }

    @Test("Cloud-only speaker hint names the local switch in Russian",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"openai","local_diarization":true}}"#),
          .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func diarizationRussianCloudOnlyHint() {
        let form = SetupForm()
        defer { form.stop() }
        #expect(Self.labels(in: form.view).contains("Доступно при включённом «На этом Mac»."))
    }

    @Test("Only a card's download button fetches its snapshotted speaker model",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .enabled(if: Platform.supportsLocalModels))
    func diarizationDownloadIsExplicitAndIndependent() async throws {
        let form = SetupForm()
        defer { form.stop() }
        let gate = Gate()
        var fetched: [DiarizationModel] = []
        form.fetchDiarization = { model, _ in
            fetched.append(model)
            await gate.pass()
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let ami = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let nemo = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.ls-eend-ami", in: form))
        toggle.performClick(nil)
        #expect(ami.accessibilityPerformPress())
        #expect(fetched.isEmpty, "selecting a model fetched it silently")
        download.performClick(nil)
        for _ in 0..<10 where fetched.isEmpty { await Task.yield() }
        #expect(fetched == [.lsEendAMI])
        #expect(!download.isEnabled)
        #expect(nemo.accessibilityPerformPress())
        #expect(Config.diarizationModel() == .nemotron3)
        #expect(fetched == [.lsEendAMI], "changing selection changed the active fetch")
        gate.open()
        for _ in 0..<50 where !download.isEnabled { await Task.yield() }
        #expect(download.isEnabled)
    }

    @Test("Every model card owns a hidden progress bar and named cancel control",
          .freshHome, .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func modelProgressBelongsToItsCard() throws {
        let form = SetupForm()
        defer { form.stop() }
        for (id, name) in [
            ("parakeet", "Parakeet v3"),
            ("whisper", "Whisper large-v3-turbo"),
            ("gigaam", "GigaAM v3"),
            ("diarization.nemotron-3", "Nemotron 3"),
            ("diarization.ls-eend-ami", "LS-EEND AMI"),
            ("diarization.community-1", "Community-1"),
        ] {
            let card = try #require(Self.view("choice.\(id)", in: form) as? ChoiceCard)
            let bars = card.allDescendants.compactMap { $0 as? NSProgressIndicator }
            let cancel = try #require(card.allDescendants
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel()?.contains(name) == true
                    && $0.accessibilityLabel()?.contains("Cancel") == true })
            #expect(bars.count == 1, "\(name) has no progress bar inside its card")
            #expect(cancel.isHiddenOrHasHiddenAncestor)
        }
    }

    @Test("Cancel stops Parakeet without losing the selected engine or showing an error",
          .freshHome, .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func parakeetCancelRestoresDownload() async throws {
        let form = Self.localForm()
        defer { form.stop() }
        let gate = Gate()
        form.parakeetIsHere = { false }
        form.fetchParakeet = {
            await gate.pass()
            try Task.checkCancellation()
        }
        form.refresh()

        let card = try #require(Self.view("choice.parakeet", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.download.parakeet", in: form))
        download.performClick(nil)
        let bar = try #require(card.allDescendants.compactMap { $0 as? NSProgressIndicator }.first)
        let cancel = try #require(card.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel()?.contains("Cancel") == true })
        #expect(form.isDownloading)
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        #expect(!cancel.isHiddenOrHasHiddenAncestor && cancel.isEnabled)

        cancel.performClick(nil)
        gate.open()
        for _ in 0..<100 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(card.isSelected)
        #expect(!download.isHidden && download.isEnabled)
        #expect(!card.status.localizedLowercase.contains("failed"))
    }

    @Test("Speaker progress stays in its card and ignores a cancelled attempt's late callback",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .speaking(.russian), .enabled(if: Platform.supportsLocalModels))
    func diarizationCancelAndRetryIgnoreStaleProgress() async throws {
        let form = SetupForm()
        defer { form.stop() }
        let gates = [Gate(), Gate()]
        var callbacks: [@Sendable (Double) -> Void] = []
        form.fetchDiarization = { _, progress in
            let attempt = callbacks.count
            callbacks.append(progress)
            await gates[attempt].pass()
            try Task.checkCancellation()
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let other = try #require(Self.view("choice.diarization.ls-eend-ami", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        toggle.performClick(nil)
        download.performClick(nil)
        for _ in 0..<100 where callbacks.isEmpty { await Task.yield() }
        let first = try #require(callbacks.first)
        first(0.37)
        for _ in 0..<100 where !Self.labels(in: card).contains("Загрузка · 37%") {
            await Task.yield()
        }
        let bar = try #require(card.allDescendants.compactMap { $0 as? NSProgressIndicator }.first)
        let cancel = try #require(card.allDescendants.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel()?.contains("Nemotron 3") == true
                && $0.accessibilityLabel()?.contains("Отменить") == true })
        #expect(Self.labels(in: card).contains("Загрузка · 37%"))
        #expect(!bar.isHiddenOrHasHiddenAncestor)
        #expect(abs(bar.doubleValue / bar.maxValue - 0.37) < 0.01)
        #expect(other.allDescendants.compactMap { $0 as? NSProgressIndicator }
            .allSatisfy { $0.isHiddenOrHasHiddenAncestor })

        toggle.performClick(nil)
        #expect(!card.isEnabled)
        #expect(cancel.isEnabled && !cancel.isHiddenOrHasHiddenAncestor,
                "turning off the feature must not trap an active download")
        cancel.performClick(nil)
        gates[0].open()
        for _ in 0..<100 where download.isHidden { await Task.yield() }
        toggle.performClick(nil)
        for _ in 0..<100 where !download.isEnabled { await Task.yield() }
        #expect(!download.isHidden && download.isEnabled)
        #expect(!card.status.contains("ошибка"))

        download.performClick(nil)
        for _ in 0..<100 where callbacks.count < 2 { await Task.yield() }
        let second = try #require(callbacks.last)
        first(0.95)
        second(0.42)
        for _ in 0..<100 where !Self.labels(in: card).contains("Загрузка · 42%") {
            await Task.yield()
        }
        #expect(Self.labels(in: card).contains("Загрузка · 42%"))
        #expect(abs(bar.doubleValue / bar.maxValue - 0.42) < 0.01)
        gates[1].open()
        for _ in 0..<100 where download.isHidden { await Task.yield() }
        #expect(!download.isHidden, "the test left a fetch active after opening its gate")
    }

    @Test("A failed speaker fetch explains the HTTP failure and offers retry",
          .freshHome(config: #"{"transcription":{"enabled":true,"engine":"parakeet"}}"#),
          .speaking(.english), .enabled(if: Platform.supportsLocalModels))
    func diarizationDownloadShowsHTTPFailure() async throws {
        let form = SetupForm()
        defer { form.stop() }
        form.fetchDiarization = { _, _ in
            throw VerifiedModelStore.Error.badHTTPStatus(404)
        }
        let toggle = try #require(Self.view("transcription.local-diarization", in: form) as? NSSwitch)
        let card = try #require(Self.view("choice.diarization.nemotron-3", in: form) as? ChoiceCard)
        let download = try #require(Self.button("transcription.diarization.download.nemotron-3", in: form))
        let progress = try #require(card.allDescendants
            .compactMap { $0 as? ModelDownloadProgress }.first)
        toggle.performClick(nil)
        download.performClick(nil)
        for _ in 0..<100 where progress.isHidden == false { await Task.yield() }

        #expect(card.status.contains("HTTP 404"), "the error hid the actionable HTTP status")
        #expect(download.title == "Retry…" && download.isEnabled && !download.isHidden)
        #expect(progress.isHidden)
    }

    /// A form whose transcription settings live in memory and say "parakeet,
    /// on this Mac", so the local model is the thing it is waiting for.
    private static func localForm() -> SetupForm {
        let form = SetupForm()
        form.storedTranscription = {
            TranscriptionChoice.read(
                engine: "parakeet", cloudProvider: "assemblyai", enabled: true,
                localModels: Platform.supportsLocalModels, localEngine: "parakeet")
        }
        form.write = { _, _ in }
        form.refresh()
        return form
    }

    /// Closing the window stopped the bar's timer and, with it, the form's
    /// only record that a download was running — so opening it again offered
    /// the download a second time, into the same cache, beside the first.
    @Test(
        "A parakeet download outlives the window closing, and reopening does not start another",
        .enabled(if: Platform.supportsLocalModels))
    func parakeetDownloadSurvivesClosing() async throws {
        let form = Self.localForm()
        let gate = Gate()
        var fetches = 0
        form.parakeetIsHere = { false }
        form.fetchParakeet = {
            fetches += 1
            await gate.pass()
        }
        form.refresh()

        // The card's own button rather than the wizard's: on a Mac where the
        // test runner has never been asked for the microphone, the wizard's
        // next step is that prompt, not the download.
        let download = try #require(Self.button("transcription.download.parakeet", in: form))
        download.performClick(nil)
        #expect(form.isDownloading)
        await Task.yield()
        #expect(fetches == 1)

        form.stop()
        #expect(form.isDownloading, "putting the window away forgot the download")
        form.reload()
        #expect(form.progress.machine.localModelDownloading)
        #expect(download.isHidden, "the download was offered again while it was running")
        download.performClick(nil)
        await Task.yield()
        #expect(fetches == 1, "a second fetch started beside the first")

        gate.open()
        for _ in 0..<50 where form.isDownloading { await Task.yield() }
        #expect(!form.isDownloading)
        #expect(fetches == 1)
        form.stop()
    }

    /// The rule was written down on `isRecording` and kept only by the login
    /// item: the system-audio test opened a second tap during a meeting and
    /// played a tone the far end could hear.
    @Test("The system-audio test is refused during a recording, and says why",
          .freshHome)
    func noToneDuringARecording() async throws {
        let form = SetupForm()
        defer { form.stop() }
        var tones = 0
        form.playTestTone = { tones += 1; return .heard }
        var recording = true
        form.isRecording = { recording }
        let row = try #require(Self.view("access.system-audio", in: form) as? AccessRow)

        row.onAct?()
        for _ in 0..<5 { await Task.yield() }
        #expect(tones == 0, "a tone was played into a meeting")
        let words = Self.labels(in: row).joined(separator: " ")
        #expect(words.contains("not while a recording is running"))

        recording = false
        row.onAct?()
        for _ in 0..<5 where tones == 0 { await Task.yield() }
        #expect(tones == 1)
    }

    /// Grants are given in System Settings, and the person comes back to
    /// amanu from there. Nothing redrew the rows when they did, so the
    /// microphone row went on saying denied beside a grant that existed.
    @Test("Coming back to amanu redraws a form that is on screen, and only one that is")
    func activationRedraws() {
        let form = SetupForm()
        defer { form.stop() }
        var redraws = 0
        form.onStateChange = { redraws += 1 }

        // Counted across each post rather than from zero: a parallel test's
        // config write redraws every form, but only between these lines —
        // nothing else runs on the main thread inside them.
        var before = redraws
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(redraws == before, "a form nobody can see asked macOS for its grants")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = form.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        before = redraws
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(redraws == before + 1)
    }
}

extension SetupFormBehaviourTests {
    fileprivate static func button(_ id: String, in form: SetupForm) -> NSButton? {
        view(id, in: form) as? NSButton
    }

    fileprivate static func view(_ id: String, in form: SetupForm) -> NSView? {
        var pending: [NSView] = [form.view]
        while let view = pending.popLast() {
            if view.identifier?.rawValue == id { return view }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The words on screen under a view, hidden ones left out.
    fileprivate static func labels(in root: NSView) -> [String] {
        var found: [String] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let label = view as? NSTextField, !label.isHidden { found.append(label.stringValue) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}
