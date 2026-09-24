import Foundation
import Testing

@testable import amanu

@Suite(.timeLimit(.minutes(1)))
struct CodexModelTests {
    @Test("An unset model leaves Codex's default alone without changing the API default")
    func defaultsAreSeparate() {
        let configurations: [[String: Any]?] = [
            nil, [:], ["summary": ["backend": "codex-cli"]],
        ]
        for configuration in configurations {
            let settings = Config.summary(in: configuration)
            #expect(settings.codexModel == nil)
            #expect(settings.openAIModel == "gpt-5")
        }
    }

    @Test("An explicitly configured OpenAI model still overrides both backends")
    func explicitModelIsPreserved() {
        let settings = Config.summary(in: ["summary": [
            "openai_model": "user-selected-model",
        ]])
        #expect(settings.codexModel == "user-selected-model")
        #expect(settings.openAIModel == "user-selected-model")
    }

    @Test("Clearing the model restores the CLI and API defaults")
    func emptyModelsUseDefaults() {
        for value in ["", " \n\t"] {
            let settings = Config.summary(in: ["summary": ["openai_model": value]])
            #expect(settings.codexModel == nil)
            #expect(settings.openAIModel == "gpt-5")
        }
    }

    @Test("The settings form preserves explicit models, including the API default")
    func settingsFormPreservesOverrides() throws {
        let entry = try #require(SettingsSchema.sections
            .flatMap(\.entries).first { $0.path == ["summary", "openai_model"] })
        for model in ["gpt-5", "user-selected-model"] {
            switch SettingsSchema.resolve(.text(model), for: entry) {
            case .set(let value): #expect(value as? String == model)
            default: Issue.record("An explicit model must be saved")
            }
        }
        switch SettingsSchema.resolve(.text(" \n\t"), for: entry) {
        case .clear: break
        default: Issue.record("An empty model must restore the backend defaults")
        }
    }

    @Test("Codex receives a model flag only for an explicit override",
          arguments: [nil, "user-selected-model"] as [String?])
    func cliInvocation(model: String?) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-codex-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A local stand-in records the actual invocation and writes the last
        // message file, so this exercises the transport without an account.
        let executable = dir.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        set -eu
        printf '%s\\n' "$@" > "$0.args"
        cat > "$0.stdin"
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--output-last-message" ]; then
                printf 'Test summary\\n' > "$2"
                exit 0
            fi
            shift
        done
        exit 2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let backend = LLMBackend.codexCLI(path: executable.path, model: model)
        let result = try await backend.call("Test instructions", "Synthetic meeting text")
        #expect(result == "Test summary\n")
        #expect(backend.model == model)
        let arguments = try String(
            contentsOf: URL(fileURLWithPath: executable.path + ".args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.first == "exec")
        #expect(arguments.last == "-")
        #expect(arguments.contains("--skip-git-repo-check"))
        let sandbox = try #require(arguments.firstIndex(of: "--sandbox"))
        #expect(arguments[sandbox + 1] == "read-only")
        if let model {
            let flag = try #require(arguments.firstIndex(of: "--model"))
            #expect(arguments[flag + 1] == model)
        } else {
            #expect(!arguments.contains("--model"))
            #expect(!arguments.contains("gpt-5"))
        }
        let input = try String(
            contentsOf: URL(fileURLWithPath: executable.path + ".stdin"), encoding: .utf8)
        #expect(input == "Test instructions\n\nSynthetic meeting text")
        let outputFlag = try #require(arguments.firstIndex(of: "--output-last-message"))
        #expect(!FileManager.default.fileExists(atPath: arguments[outputFlag + 1]))
    }
}
