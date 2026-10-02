import AppKit
import Foundation
import Testing

@testable import amanu

/// Where keys go, and what a key check is allowed to conclude.
@Suite(.serialized)
struct CredentialsTests {
    // MARK: - what a check concludes

    @Test("A status is works, refused, or neither — and no answer is not a refusal")
    func verdictFromStatus() {
        #expect(Credentials.verdict(status: 200) == .works)
        #expect(Credentials.verdict(status: 401) == .refused)
        #expect(Credentials.verdict(status: 403) == .refused)
        #expect(Credentials.verdict(status: 500) == .unexpected(status: 500))
        #expect(Credentials.verdict(status: 429) == .unexpected(status: 429))
        #expect(Credentials.verdict(status: nil) == .unreachable)
        // ElevenLabs' working key is the one that gets a validation error.
        #expect(Credentials.verdict(status: 422, accepted: [422]) == .works)
        #expect(Credentials.verdict(status: 200, accepted: [422]) == .unexpected(status: 200))
    }

    /// The defect: offline, every key check came back "that key was refused",
    /// and a person with a perfectly good key was told to go and get another.
    @Test("A Mac with no network is told it could not ask, not that the key was refused")
    func offlineIsUnreachable() async {
        let session = StubbedService.session { _ in .failure(URLError(.notConnectedToInternet)) }
        #expect(await Credentials.assemblyAI("key", session: session) == .unreachable)
        #expect(await Credentials.elevenLabs("key", session: session) == .unreachable)
        #expect(await SummaryKeyProbe.check(
            provider: .anthropic, key: "key", session: session) == .unreachable)

        let refused = StubbedService.session { _ in .success(401) }
        #expect(await Credentials.assemblyAI("key", session: refused) == .refused)
        let elevenLabsWorks = StubbedService.session { _ in .success(422) }
        #expect(await Credentials.elevenLabs("key", session: elevenLabsWorks) == .works)
    }

    @Test("Only a refusal says refused")
    func verdictSentences() {
        let verdicts: [Credentials.Verdict] = [.works, .unreachable, .unexpected(status: 503)]
        for verdict in verdicts {
            #expect(!verdict.sentence(keepingSaved: true).isEmpty)
            #expect(!verdict.sentence(keepingSaved: true).contains("refused"))
        }
        #expect(Credentials.Verdict.refused.sentence(keepingSaved: true).contains("refused"))
    }

    // MARK: - where a key goes

    @Test("Fish credentials prefer nonblank overrides and never bypass a named missing or empty file")
    func fishKeyPrecedence() throws {
        try withFreshHome { home in
            #expect(Config.fishAudioKey() == nil)
            let shared = Config.fishAudioSharedKeyPaths
            let firstShared = try #require(shared.first)
            let secondShared = try #require(shared.dropFirst().first)
            let configured = Home.current.expanding("~/secrets/fish")
            try Credentials.writeSecret(" \n shared-first \t", to: firstShared)
            try Credentials.writeSecret(" \t shared-second \n", to: secondShared)
            try Credentials.writeSecret(" \n owned-key \t", to: Config.fishAudioKeyPath)
            try Credentials.writeSecret(" \t configured-key \n", to: configured)
            var fish: [String: Any] = [
                "api_key": " \n inline-key \t",
                "api_key_path": "~/secrets/fish",
            ]
            try home.writeConfig(["transcription": ["fishaudio": fish]])
            #expect(Config.fishAudioKey() == "inline-key")

            for (value, expected) in [
                (" \n environment-key \t", "environment-key"),
                (" \t\n", "inline-key"),
            ] {
                let environment = Home(
                    url: Home.current.url, environment: ["FISH_API_KEY": value],
                    discoversTools: false, languageModels: { _ in [] })
                Home.$scoped.withValue(environment) {
                    #expect(Config.fishAudioKey() == expected)
                }
            }

            fish["api_key"] = " \t\n"
            try home.writeConfig(["transcription": ["fishaudio": fish]])
            #expect(Config.fishAudioKey() == "configured-key")
            try FileManager.default.removeItem(at: configured)
            #expect(Config.fishAudioKey() == nil,
                    "a named missing file must not borrow the owned or shared key")
            try Credentials.writeSecret(" \t\n", to: configured)
            #expect(Config.fishAudioKey() == nil,
                    "a named empty file is just as authoritative as a missing one")
            #expect(!Credentials.hasTranscriptionKey(for: "fishaudio"))

            fish.removeValue(forKey: "api_key_path")
            try home.writeConfig(["transcription": ["fishaudio": fish]])
            #expect(Config.fishAudioKey() == "owned-key")
            try Credentials.writeSecret(" \t\n", to: Config.fishAudioKeyPath)
            #expect(Config.fishAudioKey() == "shared-first")
            try Credentials.writeSecret(" \t\n", to: firstShared)
            #expect(Config.fishAudioKey() == "shared-second")
            try Credentials.writeSecret(" \t\n", to: secondShared)
            #expect(Config.fishAudioKey() == nil)
        }
    }

    @Test("The summary key for OpenAI itself shares the transcription key's file")
    func officialOpenAISharesTheSlot() throws {
        try withFreshHome { _ in
            let slot = Credentials.summarySlot(for: "openai-api", in: [:])
            #expect(slot.path == Config.openAIKeyPath)
            #expect(slot.isAmanus)
            #expect(Credentials.transcriptionSlot(for: "openai", in: [:]).path
                == Config.openAIKeyPath)
        }
    }

    @Test("An OpenAI-compatible endpoint's key has a file of its own")
    func compatibleEndpointHasItsOwnSlot() throws {
        let config: [String: Any] = [
            "summary": ["openai_base_url": "https://openrouter.ai/api/v1"],
        ]
        try withFreshHome(config: config) { _ in
            let slot = Credentials.summarySlot(for: "openai-api", in: config)
            #expect(slot.path == Credentials.openAICompatibleKeyPath)
            #expect(slot.path != Config.openAIKeyPath)
            #expect(slot.isAmanus)
        }
    }

    @Test("A key file named in the config is where the key is read, and written only if it is amanu's")
    func namedKeyPathIsRespected() throws {
        try withFreshHome { home in
            let inside: [String: Any] = [
                "summary": ["openai_api_key_path": "~/.config/amanu/keys/router"],
            ]
            let slot = Credentials.summarySlot(for: "openai-api", in: inside)
            #expect(slot.isNamedInConfig)
            #expect(slot.path.path == home.url.appendingPathComponent(".config/amanu/keys/router").path)
            #expect(slot.isAmanus)

            let shared: [String: Any] = [
                "summary": ["api_key_path": "~/.config/anthropic/token"],
            ]
            let sharedSlot = Credentials.summarySlot(for: "anthropic-api", in: shared)
            #expect(sharedSlot.isNamedInConfig)
            #expect(!sharedSlot.isAmanus, "a file other tools share is not amanu's to write")

            let assembly: [String: Any] = [
                "transcription": ["assemblyai": ["api_key_path": "~/elsewhere/key"]],
            ]
            #expect(!Credentials.transcriptionSlot(for: "assemblyai", in: assembly).isAmanus)
        }
    }

    @Test("The summary reads a compatible endpoint's key, and transcription goes on reading OpenAI's")
    func readersAgreeWithTheSlots() throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://api.groq.com/openai/v1"],
        ]
        try withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Credentials.summaryOpenAIKey() == nil,
                    "a third-party endpoint is never handed the OpenAI key")

            try Credentials.writeSecret("groq-key", to: Credentials.openAICompatibleKeyPath)
            #expect(Credentials.summaryOpenAIKey() == "groq-key")
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    /// `summary.openai_api_key_path` named one file for both passes, and the
    /// summary sent it to whatever its Base URL said: an OpenAI key went to
    /// OpenRouter the moment the URL changed.
    @Test("An OpenAI key named for the summary is not sent to a third-party Base URL")
    func openAIKeyStaysWithOpenAI() throws {
        let config: [String: Any] = [
            "summary": [
                "backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1",
                "openai_api_key_path": "~/secrets/openai",
            ],
        ]
        try withFreshHome(config: config) { home in
            let named = home.url.appendingPathComponent("secrets/openai")
            try Credentials.writeSecret("openai-key", to: named)

            #expect(Credentials.summaryOpenAIKey() == nil,
                    "the OpenAI key was handed to openrouter.ai")
            #expect(Credentials.summarySlot(for: "openai-api", in: config).path
                == Credentials.openAICompatibleKeyPath)

            var withRouterKey = config
            var summary = config["summary"] as! [String: Any]
            summary["openai_compatible_api_key_path"] = "~/secrets/router"
            withRouterKey["summary"] = summary
            try home.writeConfig(withRouterKey)
            try Credentials.writeSecret(
                "router-key", to: home.url.appendingPathComponent("secrets/router"))
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(Credentials.summarySlot(for: "openai-api", in: withRouterKey).isNamedInConfig)
        }
    }

    /// And the other way: an OpenRouter key named there was read by the
    /// OpenAI transcription engine and sent to api.openai.com.
    @Test("A compatible server's key is not sent to OpenAI by transcription")
    func routerKeyStaysWithTheRouter() throws {
        let config: [String: Any] = [
            "summary": [
                "backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1",
                "openai_api_key_path": "~/secrets/router",
            ],
        ]
        try withFreshHome(config: config) { home in
            try Credentials.writeSecret(
                "router-key", to: home.url.appendingPathComponent("secrets/router"))
            #expect(Config.openAIKey() == nil, "transcription read the OpenRouter key")
            #expect(Credentials.transcriptionSlot(for: "openai", in: config).path
                == Config.openAIKeyPath)

            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    @Test("Transcription's own key file is read, and an older config's summary setting still is for OpenAI")
    func transcriptionKeyFile() throws {
        try withFreshHome { home in
            let legacy: [String: Any] = ["summary": ["openai_api_key_path": "~/secrets/openai"]]
            try home.writeConfig(legacy)
            try Credentials.writeSecret(
                "legacy-key", to: home.url.appendingPathComponent("secrets/openai"))
            #expect(Config.openAIKey() == "legacy-key",
                    "a config written before the setting split lost its transcription key")
            #expect(Credentials.summaryOpenAIKey() == "legacy-key")

            let own: [String: Any] = [
                "transcription": ["openai": ["api_key_path": "~/secrets/transcribe"]],
                "summary": ["openai_base_url": "https://api.groq.com/openai/v1"],
            ]
            try home.writeConfig(own)
            try Credentials.writeSecret(
                "transcribe-key", to: home.url.appendingPathComponent("secrets/transcribe"))
            #expect(Config.openAIKey() == "transcribe-key")
            #expect(Credentials.transcriptionSlot(for: "openai", in: own).isNamedInConfig)
            #expect(Credentials.summaryOpenAIKey() == nil)
        }
    }

    @Test("A server on this Mac may still be offered the OpenAI key when nothing else was pasted")
    func loopbackEndpointFallsBackToTheOpenAIKey() throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "http://127.0.0.1:1234/v1"],
        ]
        try withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            #expect(Credentials.summaryOpenAIKey() == "openai-key")
        }
    }

    // MARK: - the form, end to end

    @Test("Fish stays pending until its wallet authenticates, then saves privately and becomes the provider",
          arguments: [false, true])
    @MainActor
    func fishSelectionWaitsForAcceptedKey(namedOwnedSlot: Bool) async throws {
        var transcription: [String: Any] = [
            "engine": "assemblyai", "cloud": "assemblyai",
            "assemblyai": ["api_key": "saved-assembly"],
        ]
        if namedOwnedSlot {
            transcription["fishaudio"] = ["api_key_path": "~/.config/amanu/keys/work/fish"]
        }
        try await withFreshHome(config: ["transcription": transcription]) { home in
            let destination = Credentials.transcriptionSlot(
                for: "fishaudio", in: Config.raw()).path
            let form = Self.fishForm(in: home)
            defer { form.stop() }
            let card = try Self.fishCard(in: form)
            let key = try Self.field("transcription.key", in: form)
            let before = try Data(contentsOf: Config.path)

            #expect(card.accessibilityPerformPress())
            form.refresh()
            #expect(card.isSelected)
            #expect(!key.isHiddenOrHasHiddenAncestor)
            #expect(Config.transcriptionEngine() == "assemblyai")
            #expect(Config.transcriptionCloudProvider() == "assemblyai")
            key.stringValue = " \t\n"
            await form.saveCloudKey()
            #expect(try Data(contentsOf: Config.path) == before)
            #expect(Config.fishAudioKey() == nil)

            let wallet = Self.fishWallet(
                .json(200, #"{"credit":0}"#), accepting: "checked-fish")
            form.checkKey = { await $0.ask(session: wallet.session) }
            key.stringValue = " \n checked-fish \t"
            await form.saveCloudKey()

            #expect(wallet.requests.count == 1)
            #expect(Config.fishAudioKey() == "checked-fish")
            #expect(try Data(contentsOf: destination) == Data("checked-fish".utf8))
            #expect(Config.transcriptionCloudProvider() == "fishaudio")
            #expect(Config.transcriptionEngine() == "fishaudio")
            #expect(Config.assemblyAIKey() == "saved-assembly")
            #expect(Config.value(.fishAudioKey, in: Config.raw()) == nil,
                    "the secret belongs in its owned file, not in the displayed config")
            if namedOwnedSlot {
                #expect(!FileManager.default.fileExists(atPath: Config.fishAudioKeyPath.path))
            }
            let fileMode = try FileManager.default.attributesOfItem(
                atPath: destination.path)[.posixPermissions] as? NSNumber
            let directoryMode = try FileManager.default.attributesOfItem(
                atPath: destination.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            #expect(fileMode?.intValue == 0o600)
            #expect(directoryMode?.intValue == 0o700)
            #expect(key.stringValue.isEmpty)
            #expect(key.isHiddenOrHasHiddenAncestor)

            let reopened = Self.fishForm(in: home)
            defer { reopened.stop() }
            #expect(try Self.fishCard(in: reopened).isSelected)
            #expect(try Self.field("transcription.key", in: reopened).isHiddenOrHasHiddenAncestor)
        }
    }

    @Test("A refused, offline, or unexpected Fish probe neither saves a key nor changes the working provider",
          arguments: [false, true])
    @MainActor
    func fishProbeFailuresKeepSavedState(replacingSaved: Bool) async throws {
        let failures: [(StubHTTP.Reply, Credentials.Verdict)] = [
            (.status(401), .refused),
            (.status(403), .refused),
            (.failure(.notConnectedToInternet), .unreachable),
            (.status(204), .unexpected(status: 204)),
            (.status(429), .unexpected(status: 429)),
            (.status(503), .unexpected(status: 503)),
        ]
        let provider = replacingSaved ? "fishaudio" : "assemblyai"
        for (reply, verdict) in failures {
            try await withFreshHome(config: [
                "transcription": ["engine": provider, "cloud": provider],
            ]) { home in
                try Credentials.writeSecret("saved-assembly", to: Config.assemblyAIKeyPath)
                if replacingSaved {
                    try Credentials.writeSecret("saved-fish", to: Config.fishAudioKeyPath)
                }
                let form = Self.fishForm(in: home)
                defer { form.stop() }
                let card = try Self.fishCard(in: form)
                #expect(card.accessibilityPerformPress())
                let beforeConfig = try Data(contentsOf: Config.path)
                let beforeKey = try? Data(contentsOf: Config.fishAudioKeyPath)
                let wallet = Self.fishWallet(reply, accepting: "replacement-fish")
                form.checkKey = { await $0.ask(session: wallet.session) }
                let key = try Self.field("transcription.key", in: form)
                key.stringValue = "replacement-fish"
                await form.saveCloudKey()

                #expect(wallet.requests.count == 1)
                #expect(try Data(contentsOf: Config.path) == beforeConfig)
                #expect((try? Data(contentsOf: Config.fishAudioKeyPath)) == beforeKey)
                #expect(Config.fishAudioKey() == (replacingSaved ? "saved-fish" : nil))
                #expect(Config.assemblyAIKey() == "saved-assembly")
                #expect(Config.transcriptionEngine() == provider)
                #expect(Config.transcriptionCloudProvider() == provider)
                #expect(key.stringValue == "replacement-fish")
                #expect(try Self.field("transcription.key.status", in: form).stringValue
                    == verdict.sentence(keepingSaved: replacingSaved))
                form.refresh()
                #expect(card.isSelected)
                #expect(Config.transcriptionCloudProvider() == provider)
            }
        }
    }

    @Test("Fish setup never creates or overwrites an externally owned configured key file",
          arguments: [false, true])
    @MainActor
    func fishExternalKeyFileIsNotWritten(existing: Bool) async throws {
        let provider = existing ? "fishaudio" : "assemblyai"
        try await withFreshHome(config: [
            "transcription": [
                "engine": provider, "cloud": provider,
                "fishaudio": ["api_key_path": "~/shared/fish-token"],
            ],
        ]) { home in
            let external = Home.current.expanding("~/shared/fish-token")
            if existing { try Credentials.writeSecret("external-fish", to: external) }
            try Credentials.writeSecret("saved-assembly", to: Config.assemblyAIKeyPath)
            let beforeKey = try? Data(contentsOf: external)
            let beforeConfig = try Data(contentsOf: Config.path)
            let form = Self.fishForm(in: home)
            defer { form.stop() }
            #expect(try Self.fishCard(in: form).accessibilityPerformPress())
            let wallet = Self.fishWallet(
                .json(200, #"{"credit":0}"#), accepting: "replacement-fish")
            form.checkKey = { await $0.ask(session: wallet.session) }
            let key = try Self.field("transcription.key", in: form)
            key.stringValue = "replacement-fish"
            await form.saveCloudKey()

            #expect(wallet.requests.isEmpty, "a key that cannot be saved is not checked")
            #expect((try? Data(contentsOf: external)) == beforeKey)
            #expect(try Data(contentsOf: Config.path) == beforeConfig)
            #expect(!FileManager.default.fileExists(atPath: Config.fishAudioKeyPath.path))
            #expect(Config.fishAudioKey() == (existing ? "external-fish" : nil))
            #expect(Config.assemblyAIKey() == "saved-assembly")
            #expect(Config.transcriptionEngine() == provider)
            #expect(Config.transcriptionCloudProvider() == provider)
            #expect(key.stringValue == "replacement-fish")
        }
    }

    @Test("Switching between OpenAI and a compatible service keeps endpoints and keys separate")
    @MainActor
    func summaryProviderSwitchKeepsEndpointsAndKeys() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://router.example/api/v1"],
        ]
        try await withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            try Credentials.writeSecret("router-key", to: Credentials.openAICompatibleKeyPath)
            let form = SetupForm()
            defer { form.stop() }
            let selector = try #require(form.view.allDescendants.compactMap { $0 as? NSSegmentedControl }
                .first { $0.label(forSegment: 0) == "OpenAI" })
            try #require(selector.segmentCount == 3)
            #expect(selector.selectedSegment == 2, "a legacy custom endpoint must select compatible")

            selector.selectedSegment = 0
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 0)
            #expect(Config.summary().openAIBaseURL == "https://api.openai.com/v1")
            #expect(Credentials.summaryOpenAIKey() == "openai-key")
            #expect(try Self.field("summary.key", in: form).placeholderString == "API key")

            selector.selectedSegment = 2
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 2)
            #expect(Config.summary().openAIBaseURL == "https://router.example/api/v1")
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(try Self.field("summary.key", in: form).placeholderString == "API key")

            var asked: [Credentials.Check] = []
            form.checkKey = { asked.append($0); return .works }
            try Self.field("summary.key", in: form).stringValue = "replacement-router-key"
            await form.saveSummaryKey()
            #expect(asked == [Credentials.Check(
                service: .openAI(baseURL: "https://router.example/api/v1"), key: "replacement-router-key")])
            #expect(Config.openAIKey() == "openai-key")
        }
    }

    @Test("Choosing a compatible service before entering its URL does not use the OpenAI key")
    @MainActor
    func compatibleProviderNeedsItsOwnEndpoint() throws {
        try withFreshHome(config: ["summary": ["backend": "openai-api"]]) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            let form = SetupForm()
            defer { form.stop() }
            let selector = try #require(form.view.allDescendants.compactMap { $0 as? NSSegmentedControl }
                .first { $0.label(forSegment: 0) == "OpenAI" })
            try #require(selector.segmentCount == 3)
            selector.selectedSegment = 2
            selector.sendAction(selector.action, to: selector.target)
            form.refresh()
            #expect(selector.selectedSegment == 2)
            #expect(Config.summary().openAIBaseURL.isEmpty)
            #expect(Credentials.summaryOpenAIKey() == nil)
            #expect(Credentials.summarySlot(for: "openai-api", in: Config.raw()).path
                == Credentials.openAICompatibleKeyPath)
        }
    }

    /// The defect itself: a key pasted for OpenRouter was checked against
    /// OpenRouter and then written over the OpenAI key, which the OpenAI
    /// transcription engine reads. Every meeting after it came back 401.
    @Test("Saving a summary key for a compatible endpoint leaves the OpenAI key alone")
    @MainActor
    func summaryKeyForAnEndpointKeepsTheOpenAIKey() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "openai-api", "openai_base_url": "https://openrouter.ai/api/v1"],
        ]
        try await withFreshHome(config: config) { _ in
            try Credentials.writeSecret("openai-key", to: Config.openAIKeyPath)
            let form = SetupForm()
            defer { form.stop() }
            var asked: [Credentials.Check] = []
            form.checkKey = { asked.append($0); return .works }

            try Self.field("summary.key", in: form).stringValue = "router-key"
            await form.saveSummaryKey()

            #expect(asked == [Credentials.Check(
                service: .openAI(baseURL: "https://openrouter.ai/api/v1"), key: "router-key")])
            #expect(Config.secret(at: Config.openAIKeyPath) == "openai-key")
            #expect(Config.secret(at: Credentials.openAICompatibleKeyPath) == "router-key")
            #expect(Credentials.summaryOpenAIKey() == "router-key")
            #expect(try Self.field("summary.key.status", in: form).stringValue == "key works")
        }
    }

    @Test("A key file the config names outside amanu's drawer is not written, and the form says where")
    @MainActor
    func summaryKeyIntoANamedSharedFileIsRefused() async throws {
        let config: [String: Any] = [
            "summary": ["backend": "anthropic-api", "api_key_path": "~/.config/anthropic/token"],
        ]
        try await withFreshHome(config: config) { home in
            let form = SetupForm()
            defer { form.stop() }
            var asked = 0
            form.checkKey = { _ in asked += 1; return .works }

            try Self.field("summary.key", in: form).stringValue = "sk-ant-new"
            await form.saveSummaryKey()

            #expect(asked == 0, "a key that cannot be saved is not worth checking")
            #expect(Config.secret(at: Config.anthropicKeyPath) == nil)
            #expect(!FileManager.default.fileExists(
                atPath: home.url.appendingPathComponent(".config/anthropic/token").path))
            let status = try Self.field("summary.key.status", in: form).stringValue
            #expect(status.contains("~/.config/anthropic/token"))
        }
    }

    @Test("Offline, a pasted cloud key is neither saved nor called refused")
    @MainActor
    func cloudKeyOffline() async throws {
        try await withFreshHome { _ in
            try Credentials.writeSecret("good-key", to: Config.assemblyAIKeyPath)
            let form = SetupForm()
            defer { form.stop() }
            form.checkKey = { _ in .unreachable }

            try Self.field("transcription.key", in: form).stringValue = "new-key"
            await form.saveCloudKey()

            #expect(Config.secret(at: Config.assemblyAIKeyPath) == "good-key")
            let status = try Self.field("transcription.key.status", in: form).stringValue
            #expect(status == Credentials.Verdict.unreachable.sentence(keepingSaved: true))
            #expect(!status.contains("refused"))
        }
    }

    private static func fishWallet(
        _ reply: StubHTTP.Reply, accepting key: String
    ) -> StubHTTP {
        StubHTTP { request, _ in
            guard request.method == "GET",
                  request.url.absoluteString == "https://api.fish.audio/wallet/self/api-credit",
                  request.header("authorization") == "Bearer \(key)"
            else { return .status(400) }
            return reply
        }
    }

    /// Config notifications are process-wide, including those from another
    /// test's home while a wallet probe is suspended. Keep this form's
    /// read/write seam attached to the home it was built for.
    @MainActor
    private static func fishForm(in home: Home) -> SetupForm {
        let form = SetupForm()
        form.storedTranscription = {
            Home.$scoped.withValue(home) {
                TranscriptionChoice.read(
                    engine: Config.transcriptionEngine(),
                    cloudProvider: Config.transcriptionCloudProvider(),
                    enabled: Config.transcriptionEnabled(),
                    localModels: Platform.supportsLocalModels,
                    localEngine: Config.transcriptionLocalEngine())
            }
        }
        form.write = { path, value in
            Home.$scoped.withValue(home) { Config.update(path: path, value: value) }
        }
        form.refresh()
        return form
    }

    @MainActor
    private static func fishCard(in form: SetupForm) throws -> ChoiceCard {
        try #require(form.view.allDescendants.compactMap { $0 as? ChoiceCard }
            .first { $0.id == "fishaudio" })
    }

    @MainActor
    private static func field(_ id: String, in form: SetupForm) throws -> NSTextField {
        var pending: [NSView] = [form.view]
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.identifier?.rawValue == id { return field }
            pending.append(contentsOf: view.subviews)
        }
        throw FieldMissing(id: id)
    }

    private struct FieldMissing: Error { let id: String }
}

/// A URL loading system that answers every request itself — with a status,
/// or with the error a Mac with no network gets.
final class StubbedService: URLProtocol, @unchecked Sendable {
    typealias Answer = @Sendable (URLRequest) -> Result<Int, URLError>

    /// One answer per session, found by the header this adds to every request
    /// it makes, so suites running at once cannot answer for each other.
    private static let answers = Answers()

    static func session(_ answer: @escaping Answer) -> URLSession {
        let id = UUID().uuidString
        answers.set(id, answer)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedService.self]
        configuration.httpAdditionalHeaders = ["x-stub": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "x-stub") ?? ""
        guard let answer = Self.answers.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch answer(request) {
        case .success(let status):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: StubbedService.Answer] = [:]

    func set(_ id: String, _ answer: @escaping StubbedService.Answer) {
        lock.withLock { byID[id] = answer }
    }

    func get(_ id: String) -> StubbedService.Answer? {
        lock.withLock { byID[id] }
    }
}
