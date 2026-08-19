import Foundation

/// Translation between the setup window's human choices and the existing
/// config vocabulary. The Claude card deliberately represents `auto`: it is
/// the preferred subscription, while the fallback chain still saves a summary
/// when Claude is unavailable or out of allowance.
enum SetupSelection {
    static func summaryBackend(choice: String, keyBackend: String) -> String? {
        switch choice {
        case "claude-cli": return nil
        case "api-key": return keyBackend
        default: return choice
        }
    }

    static func summaryChoice(backend: String) -> String {
        switch backend {
        case "auto", "claude-cli": return "claude-cli"
        case "anthropic-api", "openai-api": return "api-key"
        default: return backend
        }
    }
}

/// The transcription section's two switches and its provider, in the
/// vocabulary the config file speaks.
///
/// The window asks two questions — may audio leave this Mac, and should the
/// local model be kept ready — and the config answers them with one `engine`
/// string. The translation is here rather than in the window so the whole
/// matrix, including the Intel half of the universal binary, can be tested
/// without opening anything.
struct TranscriptionChoice: Equatable {
    var cloud: Bool
    var local: Bool
    /// Which cloud service, whether or not the cloud is switched on. Kept
    /// even while it is off: turning the switch back on should not lose the
    /// answer, and the card is on screen the whole time either way.
    var provider: String

    static func read(
        engine: String,
        cloudProvider: String,
        enabled: Bool,
        localModels: Bool
    ) -> TranscriptionChoice {
        let named = Config.cloudEngines.contains(engine)
        let provider = named ? engine : cloudProvider
        guard enabled else {
            return TranscriptionChoice(cloud: false, local: false, provider: provider)
        }
        // Anything that isn't a provider name or "parakeet" is auto — the
        // default, and what an unreadable value falls back to elsewhere too.
        let auto = !named && engine != "parakeet"
        return TranscriptionChoice(
            cloud: named || auto,
            local: localModels && (auto || engine == "parakeet"),
            provider: provider
        )
    }

    /// Whether the local model has been asked for and is not on the disk.
    ///
    /// It is a question about the switch, not about the engine's name — both
    /// switches on writes no engine at all, and that setting is still asking
    /// for the local model: it is the one that keeps transcribing when the
    /// network doesn't, and the download is the whole of what makes it true.
    /// Asked of the engine string instead, the window went quiet in the most
    /// ordinary case there is.
    func needsLocalModel(downloaded: Bool) -> Bool {
        local && !downloaded
    }

    /// What to write, as paths into the config with nil meaning "remove it".
    /// Defaults are removed rather than written out: a config file that only
    /// contains what was actually chosen is one a person can read.
    var updates: [(path: [String], value: Any?)] {
        guard cloud || local else {
            // Neither engine is a real answer — record only, transcription off
            // — and the engine setting is left alone so switching back on
            // remembers what it was.
            return [(["transcription", "enabled"], false)]
        }
        let engine: String? = cloud && local ? nil : (cloud ? provider : "parakeet")
        return [
            (["transcription", "enabled"], nil),
            (["transcription", "engine"], engine),
            (["transcription", "cloud"], provider == "assemblyai" ? nil : provider),
        ]
    }
}

/// A no-cost authentication check for the two summary API providers. Both
/// official APIs expose an authenticated model-list endpoint, so setup can
/// verify a key without generating (and billing for) any text.
enum SummaryKeyProbe {
    enum Provider {
        case anthropic
        case openAI
    }

    static func request(provider: Provider, key: String) -> URLRequest {
        let url: URL
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/models")!
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    static func works(provider: Provider, key: String) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(
            for: request(provider: provider, key: key)
        ) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
