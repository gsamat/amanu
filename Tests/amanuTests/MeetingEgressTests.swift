import Foundation
import Testing

@testable import amanu

/// Where the words of a meeting may go. The setup window promises that
/// choosing Ollama keeps them on this Mac and that turning summaries off
/// sends them nowhere; these hold every pass that reads a transcript to it.
struct MeetingEgressTests {
    private static func route(
        _ purpose: MeetingEgress.Purpose, summary: [String: Any] = [:],
        names: [String: Any] = [:]
    ) -> MeetingEgress.Route? {
        let root: [String: Any] = ["summary": summary, "speaker_names": names]
        var settings = Config.SpeakerNamesSettings()
        if let enabled = names["enabled"] as? Bool { settings.enabled = enabled }
        if let backend = names["backend"] as? String { settings.backend = backend }
        if let model = names["model"] as? String { settings.model = model }
        return MeetingEgress.route(
            for: purpose, summary: Config.summary(in: root), names: settings)
    }

    // MARK: - the rule

    @Test("Naming goes wherever the summary goes")
    func namingFollowsTheSummary() {
        for backend in ["auto", "claude-cli", "codex-cli", "anthropic-api", "openai-api", "ollama"] {
            #expect(Self.route(.speakerNames, summary: ["backend": backend])?.preference == backend)
            #expect(Self.route(.summary, summary: ["backend": backend])?.preference == backend)
        }
    }

    @Test("With summaries off, naming asks no model unless it was given one of its own")
    func summariesOffMeansNamingAsksNobody() {
        #expect(Self.route(.speakerNames, summary: ["enabled": false]) == nil)
        #expect(Self.route(.speakerNames, summary: ["backend": "none"]) == nil)
        #expect(Self.route(.summary, summary: ["backend": "none"]) == nil)
        #expect(Self.route(
            .speakerNames, summary: ["enabled": false], names: ["backend": "ollama"]
        )?.preference == "ollama")
    }

    @Test("Naming's own backend wins over the summary's, and none means none")
    func namingsOwnBackend() {
        #expect(Self.route(
            .speakerNames, summary: ["backend": "claude-cli"], names: ["backend": "ollama"]
        )?.preference == "ollama")
        #expect(Self.route(
            .speakerNames, summary: ["backend": "claude-cli"], names: ["backend": "none"]
        ) == nil)
        #expect(Self.route(
            .speakerNames, summary: ["backend": "ollama"], names: ["backend": "summary"]
        )?.preference == "ollama")
        #expect(Self.route(.speakerNames, names: ["enabled": false]) == nil)
    }

    @Test("A model chosen by hand is carried; the default is left to each backend")
    func modelsAreCarriedOnlyWhenChosen() {
        #expect(Self.route(.summary)?.anthropicModel == nil)
        #expect(Self.route(.summary, summary: ["model": "claude-sonnet-5"])?.anthropicModel
            == "claude-sonnet-5")
        #expect(Self.route(.speakerNames, summary: ["model": "claude-sonnet-5"])?.anthropicModel
            == "claude-sonnet-5")
        #expect(Self.route(
            .speakerNames, summary: ["model": "claude-sonnet-5"], names: ["model": "claude-haiku-5"]
        )?.anthropicModel == "claude-haiku-5")
    }

    @Test("A preference nobody recognises allows no backend at all")
    func anUnknownPreferenceAllowsNothing() {
        let backends = ["claude-cli", "codex-cli", "ollama"].map {
            LLMBackend(name: $0, model: nil) { _, _ in "" }
        }
        #expect(LLMBackend.chain(preference: "olama", from: backends).isEmpty)
        #expect(LLMBackend.chain(preference: "auto", from: backends).map(\.name)
            == ["claude-cli", "codex-cli", "ollama"])
        #expect(LLMBackend.chain(preference: "codex-cli", from: backends).map(\.name)
            == ["codex-cli"])
    }

    // MARK: - end to end, with every backend present

    /// Every backend is installed and answering; the config alone decides
    /// who is asked.
    private static func finish(config: [String: Any]) async throws
        -> (asked: [String: Int], dir: URL)
    {
        let models = ["claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama"]
            .map(FakeModel.working)
        let home = Home.withModels(models)
        defer { try? FileManager.default.removeItem(at: home.url) }
        var config = config
        config["user_name"] = "Самат"
        try home.writeConfig(config)
        let dir = try SessionFixture.make()

        await Home.$scoped.withValue(home) { _ = await PostProcessor.finish(dir) }
        let asked = Dictionary(uniqueKeysWithValues: models.map { ($0.name, $0.callCount) })
            .filter { $0.value > 0 }
        return (asked, dir)
    }

    @Test("Ollama selected: only Ollama reads the meeting, for names and summary both")
    func ollamaSelectedAsksOnlyOllama() async throws {
        let (asked, dir) = try await Self.finish(config: ["summary": ["backend": "ollama"]])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(asked == ["ollama": 2])
        #expect(SpeakerNames.read(from: dir)?.speakers["them A"]?.name == "Фёдор")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
    }

    @Test("Codex selected: only Codex reads the meeting")
    func codexSelectedAsksOnlyCodex() async throws {
        let (asked, dir) = try await Self.finish(config: ["summary": ["backend": "codex-cli"]])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(asked == ["codex-cli": 2])
    }

    @Test("Summaries off: no model reads the meeting, and only the owner is named")
    func summariesOffAsksNobody() async throws {
        for summary: [String: Any] in [["backend": "none"], ["enabled": false]] {
            let (asked, dir) = try await Self.finish(config: ["summary": summary])
            defer { try? FileManager.default.removeItem(at: dir) }
            #expect(asked.isEmpty)
            let names = try #require(SpeakerNames.read(from: dir))
            #expect(names.speakers["me"]?.name == "Самат")
            #expect(names.speakers["them A"]?.name == nil)
            #expect(!FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("summary.md").path))
        }
    }

    // MARK: - how the CLIs are asked

    /// The transcript is untrusted: anyone on the call can dictate
    /// instructions into it. Each flag here takes something away from the
    /// agent the CLI would otherwise be, and none of them may quietly go.
    @Test("The claude CLI is asked with no tools, no settings, no MCP and no history")
    func claudeArgumentsArePinned() {
        #expect(LLMBackend.claudeArguments(system: "Take notes.", model: nil) == [
            "--print",
            "--system-prompt", "Take notes.",
            "--output-format", "text",
            "--tools", "",
            "--setting-sources", "",
            "--mcp-config", #"{"mcpServers":{}}"#,
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
        ])
        #expect(Array(LLMBackend.claudeArguments(system: "x", model: "claude-sonnet-5").suffix(2))
            == ["--model", "claude-sonnet-5"])
    }

    @Test("Codex keeps its own model, runs read-only and leaves no session behind")
    func codexArgumentsArePinned() {
        let output = URL(fileURLWithPath: "/tmp/answer.txt")
        #expect(LLMBackend.codexArguments(output: output, mcpServers: []) == [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ephemeral",
            "--output-last-message", "/tmp/answer.txt",
            "-",
        ])
    }

    /// The read-only sandbox does not reach an MCP server's tools, which run
    /// in the server's own process. `-c mcp_servers={}` would have been the
    /// obvious override, and codex merges it into the file's table instead
    /// of replacing it — so every server is switched off by name.
    @Test("Every MCP server in the codex config is switched off for the run")
    func codexMCPServersAreOff() {
        let output = URL(fileURLWithPath: "/tmp/answer.txt")
        let arguments = LLMBackend.codexArguments(
            output: output, mcpServers: ["github", "fs-tools"])
        #expect(arguments == [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ephemeral",
            "-c", "mcp_servers.github.enabled=false",
            "-c", "mcp_servers.fs-tools.enabled=false",
            "--output-last-message", "/tmp/answer.txt",
            "-",
        ])

        // A name codex would split on its dot, or servers that could not be
        // named at all: the config file is not read.
        for unnameable in [["my.server"], nil] as [[String]?] {
            let skipped = LLMBackend.codexArguments(
                output: output, mcpServers: unnameable)
            #expect(skipped.contains("--ignore-user-config"))
            #expect(!skipped.contains("-c"))
            #expect(!skipped.contains("--model"))
        }
    }

    @Test("MCP servers are found in every shape a TOML file can give them")
    func mcpServerNamesAreRead() {
        let toml = """
        model = "gpt-5"
        mcp_servers.inline.command = "a"

        [mcp_servers.github]
        command = "gh-mcp"

        [mcp_servers.github.env]
        TOKEN = "x"

        [mcp_servers."quoted-name"]
        command = "q"

        [mcp_servers]
        tabled = { command = "t" }
        # commented = { command = "c" }

        [profiles.work]
        mcp_servers = "not a server"
        """
        #expect(LLMBackend.mcpServerNames(inTOML: toml)
            == ["inline", "github", "quoted-name", "tabled"])
        #expect(LLMBackend.mcpServerNames(inTOML: "model = \"gpt-5\"\n") == [])
        #expect(LLMBackend.mcpServerNames(inTOML: "mcp_servers = {x={command=\"y\"}}") == nil)
    }
}
