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
