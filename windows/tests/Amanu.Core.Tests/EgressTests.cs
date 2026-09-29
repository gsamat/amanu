using Amanu.Core.Configuration;
using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class EgressTests
{
    private static AppSettings Settings(bool summary = true, string backend = "auto", string names = "summary", bool namesOn = true)
    {
        var settings = AppSettings.CreateDefault("C:\\Docs");
        settings.Summary.Enabled = summary;
        settings.Summary.Backend = backend;
        settings.SpeakerNames.Backend = names;
        settings.SpeakerNames.Enabled = namesOn;
        return settings;
    }

    [Fact]
    public void Naming_follows_the_summary_to_ollama()
    {
        Assert.Equal("ollama", MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(backend: "ollama"))!.Preference);
    }

    [Fact]
    public void With_summaries_off_naming_asks_no_model()
    {
        Assert.Null(MeetingEgress.Route(EgressPurpose.Summary, Settings(summary: false)));
        Assert.Null(MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(summary: false)));
        Assert.Null(MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(backend: "none")));
    }

    [Fact]
    public void An_explicit_naming_backend_is_a_choice_for_naming_alone()
    {
        Assert.Equal("anthropic-api", MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(summary: false, names: "anthropic-api"))!.Preference);
        Assert.Null(MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(names: "none")));
        Assert.Null(MeetingEgress.Route(EgressPurpose.SpeakerNames, Settings(namesOn: false)));
    }

    [Fact]
    public void A_misspelt_backend_allows_nothing_rather_than_everything()
    {
        Assert.Empty(LanguageModelChain.Allowed("olama", _ => true));
        Assert.Equal(["ollama"], LanguageModelChain.Allowed("ollama", _ => true));
        Assert.Equal(["anthropic-api", "ollama"], LanguageModelChain.Allowed("auto", name => name is "anthropic-api" or "ollama"));
    }

    [Theory]
    [InlineData("https://api.openai.com/v1", "openai-key")]
    [InlineData("https://openrouter.ai/api/v1", "compatible-key")]
    [InlineData("http://127.0.0.1:8080/v1", "compatible-key")]
    public void Each_key_goes_only_to_its_own_service(string baseUrl, string expected)
    {
        Assert.Equal(expected, KeyRouting.SummaryOpenAiKey(baseUrl, "openai-key", "compatible-key"));
    }

    [Fact]
    public void The_openai_key_never_reaches_a_remote_compatible_server()
    {
        Assert.Null(KeyRouting.SummaryOpenAiKey("https://openrouter.ai/api/v1", "openai-key", null));
        Assert.Equal("openai-key", KeyRouting.SummaryOpenAiKey("http://localhost:1234/v1", "openai-key", null));
    }

    [Theory]
    [InlineData("https://ollama.example.com", true)]
    [InlineData("http://127.0.0.1:11434", true)]
    [InlineData("http://192.168.1.5:11434", false)]
    public void Plain_http_is_only_accepted_on_this_computer(string url, bool acceptable)
    {
        Assert.Equal(acceptable, KeyRouting.AcceptableServer(url));
    }

    [Fact]
    public void Every_server_setting_is_one_advanced_can_edit()
    {
        var advanced = SettingsSchema.AdvancedSections.SelectMany(section => section.Entries).Select(entry => entry.Path).ToHashSet();
        Assert.Equal(["summary.ollama_base_url", "summary.openai_base_url"], KeyRouting.ServerSettings.Order());
        Assert.All(KeyRouting.ServerSettings, path => Assert.Contains(path, advanced));
    }
}

public sealed class CliArgumentsTests
{
    [Fact]
    public void Claude_is_asked_with_no_tools_settings_mcp_or_history()
    {
        var arguments = CliArguments.Claude("C:\\t\\system.txt", null);
        Assert.Equal(
            ["--print", "--system-prompt-file", "C:\\t\\system.txt", "--output-format", "text", "--tools", "",
             "--setting-sources", "", "--mcp-config", """{"mcpServers":{}}""", "--strict-mcp-config",
             "--disable-slash-commands", "--no-session-persistence"],
            arguments);
        Assert.Equal(["--model", "claude-opus-5"], CliArguments.Claude("f", "claude-opus-5").TakeLast(2));
    }

    [Fact]
    public void Codex_switches_off_every_named_mcp_server()
    {
        var arguments = CliArguments.Codex("gpt-5", "out.txt", ["github", "files"]);
        Assert.Equal(
            ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
             "-c", "mcp_servers.github.enabled=false", "-c", "mcp_servers.files.enabled=false",
             "--model", "gpt-5", "--output-last-message", "out.txt", "-"],
            arguments);
    }

    [Fact]
    public void Codex_skips_the_config_when_servers_cannot_be_named()
    {
        Assert.Contains("--ignore-user-config", CliArguments.Codex("gpt-5", "o", null));
        Assert.Contains("--ignore-user-config", CliArguments.Codex("gpt-5", "o", ["has.dot"]));
    }

    [Fact]
    public void Mcp_servers_are_found_in_every_toml_shape()
    {
        const string toml = """
            model = "gpt-5"
            mcp_servers.top.command = "x"
            [mcp_servers.github]
            command = "gh"
            [mcp_servers.github.env]
            TOKEN = "t"
            [mcp_servers]
            inline = { command = "y" }
            """;
        Assert.Equal(["top", "github", "inline"], CliArguments.McpServerNames(toml));
        Assert.Empty(CliArguments.McpServerNames("model = \"gpt-5\"")!);
        Assert.Null(CliArguments.McpServerNames("# mcp_servers are defined elsewhere\nx = \"mcp_servers\""));
    }
}
