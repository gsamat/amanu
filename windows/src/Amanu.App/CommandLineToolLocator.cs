using System.IO;

namespace Amanu.App;

/// <summary>Finds standalone CLIs and the copies bundled with desktop apps.</summary>
internal static class CommandLineToolLocator
{
    public static string? Find(string name, string home, string appData, string local, string searchPath)
    {
        var places = new List<string>
        {
            Path.Combine(home, ".local", "bin"),
            Path.Combine(appData, "npm"),
            Path.Combine(local, "Programs", name),
        };
        places.AddRange(searchPath.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var directory in places)
        foreach (var extension in new[] { ".exe", ".cmd" })
        {
            var candidate = Path.Combine(directory.Trim('"'), name + extension);
            if (File.Exists(candidate)) return candidate;
        }

        return name switch
        {
            "claude" => NewestCopy(ClaudeDirectories(appData, local), "claude.exe"),
            "codex" => NewestCopy([Path.Combine(local, "OpenAI", "Codex", "bin")], "codex.exe"),
            _ => null,
        };
    }

    private static IEnumerable<string> ClaudeDirectories(string appData, string local)
    {
        yield return Path.Combine(appData, "Claude", "claude-code");
        // MSIX redirects Claude Desktop's roaming AppData into its package's
        // LocalCache. Other processes see only this physical path, even though
        // Claude's process path appears to be in the ordinary roaming folder.
        var packages = Path.Combine(local, "Packages");
        if (!Directory.Exists(packages)) yield break;
        string[] directories;
        try
        {
            directories = Directory.GetDirectories(packages, "Claude_*", SearchOption.TopDirectoryOnly);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            yield break;
        }
        foreach (var package in directories)
            yield return Path.Combine(package, "LocalCache", "Roaming", "Claude", "claude-code");
    }

    /// <summary>
    /// Updates leave version/hash folders behind; use the most recently written
    /// CLI. Claude's bundled copy may need its own sign-in outside the desktop
    /// app. Codex's bundled copy shares ~/.codex with its desktop app.
    /// </summary>
    private static string? NewestCopy(IEnumerable<string> directories, string file)
    {
        var copies = new List<FileInfo>();
        foreach (var directory in directories)
        {
            if (!Directory.Exists(directory)) continue;
            try
            {
                copies.AddRange(new DirectoryInfo(directory).EnumerateFiles(file, new EnumerationOptions
                {
                    RecurseSubdirectories = true,
                    IgnoreInaccessible = true,
                }));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // One unavailable install must not hide another usable copy.
            }
        }
        return copies.OrderByDescending(found => found.LastWriteTimeUtc).FirstOrDefault()?.FullName;
    }
}
