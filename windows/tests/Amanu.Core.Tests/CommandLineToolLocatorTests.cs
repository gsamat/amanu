using Amanu.App;

namespace Amanu.Core.Tests;

public sealed class CommandLineToolLocatorTests
{
    [Fact]
    public void Finds_claude_bundled_with_msix_desktop_without_path_or_roaming_install()
    {
        using var temp = new TemporaryDirectory();
        var cli = Create(temp, "local", "Packages", "Claude_pzs8sxrjxfjjc", "LocalCache", "Roaming",
            "Claude", "claude-code", "2.1.284", "claude.exe");

        Assert.Equal(cli, Find(temp, "claude"));
    }

    [Fact]
    public void Uses_newest_cli_across_desktop_versions_and_package_families()
    {
        using var temp = new TemporaryDirectory();
        var old = Create(temp, "roaming", "Claude", "claude-code", "2.1.100", "claude.exe");
        var previous = Create(temp, "local", "Packages", "Claude_old", "LocalCache", "Roaming",
            "Claude", "claude-code", "2.1.200", "claude.exe");
        var newest = Create(temp, "local", "Packages", "Claude_current", "LocalCache", "Roaming",
            "Claude", "claude-code", "2.1.284", "claude.exe");
        File.SetLastWriteTimeUtc(old, new DateTime(2026, 9, 1));
        File.SetLastWriteTimeUtc(previous, new DateTime(2026, 9, 2));
        File.SetLastWriteTimeUtc(newest, new DateTime(2026, 9, 3));

        Assert.Equal(newest, Find(temp, "claude"));
    }

    [Theory]
    [InlineData("claude", "roaming", "Claude", "claude-code", "2.1.284", "claude.exe")]
    [InlineData("codex", "local", "OpenAI", "Codex", "bin", "hash", "codex.exe")]
    public void Keeps_finding_unpacked_desktop_clis(string name, params string[] parts)
    {
        using var temp = new TemporaryDirectory();
        var cli = Create(temp, parts);

        Assert.Equal(cli, Find(temp, name));
    }

    [Fact]
    public void Prefers_standalone_claude_over_bundled_copy()
    {
        using var temp = new TemporaryDirectory();
        Create(temp, "local", "Packages", "Claude_current", "LocalCache", "Roaming",
            "Claude", "claude-code", "2.1.284", "claude.exe");
        var standalone = Create(temp, "home", ".local", "bin", "claude.exe");

        Assert.Equal(standalone, Find(temp, "claude"));
    }

    [Fact]
    public void Finds_npm_shims_and_quoted_path_entries()
    {
        using var temp = new TemporaryDirectory();
        var npm = Create(temp, "roaming", "npm", "claude.cmd");
        var codex = Create(temp, "tools with spaces", "codex.exe");

        Assert.Equal(npm, Find(temp, "claude"));
        Assert.Equal(codex, Find(temp, "codex", '"' + Path.GetDirectoryName(codex) + '"'));
    }

    [Fact]
    public void Does_not_treat_desktop_exe_or_other_packages_as_claude_code()
    {
        using var temp = new TemporaryDirectory();
        Create(temp, "local", "Packages", "Claude_current", "app", "claude.exe");
        Create(temp, "local", "Packages", "Unrelated_current", "LocalCache", "Roaming",
            "Claude", "claude-code", "2.1.284", "claude.exe");

        Assert.Null(Find(temp, "claude"));
    }

    [Fact]
    public void Missing_install_returns_null()
    {
        using var temp = new TemporaryDirectory();
        Assert.Null(Find(temp, "claude"));
        Assert.Null(Find(temp, "codex"));
    }

    private static string? Find(TemporaryDirectory temp, string name, string searchPath = "") =>
        CommandLineToolLocator.Find(name, Path.Combine(temp.Path, "home"), Path.Combine(temp.Path, "roaming"),
            Path.Combine(temp.Path, "local"), searchPath);

    private static string Create(TemporaryDirectory temp, params string[] parts)
    {
        var path = Path.Combine([temp.Path, .. parts]);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "test executable");
        return path;
    }
}
