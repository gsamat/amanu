namespace Amanu.Core.Recording;

public sealed class CallProcessMatcher(
    IEnumerable<string> callProcesses,
    IEnumerable<string> ignoreProcesses)
{
    private readonly Dictionary<string, string> calls = callProcesses
        .Select(Normalize)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToDictionary(name => name, name => EnsureExe(name), StringComparer.OrdinalIgnoreCase);

    private readonly HashSet<string> ignored = ignoreProcesses
        .Select(Normalize)
        .ToHashSet(StringComparer.OrdinalIgnoreCase);

    public string? Match(string observedProcess)
    {
        var normalized = Normalize(observedProcess);
        if (ignored.Contains(normalized))
        {
            return null;
        }

        return calls.TryGetValue(normalized, out var configured) ? configured : null;
    }

    private static string Normalize(string process)
    {
        var fileName = process.Replace('\\', '/').Split('/').LastOrDefault() ?? string.Empty;
        return fileName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? fileName[..^4]
            : fileName;
    }

    private static string EnsureExe(string processName) => processName + ".exe";
}
