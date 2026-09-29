namespace Amanu.Core.Recording;

/// <summary>
/// Which process holding the microphone counts as a call. An empty list of call
/// apps means any process at all, as on macOS; the ignore list wins over both.
/// </summary>
public sealed class CallProcessMatcher(IEnumerable<string> callProcesses, IEnumerable<string> ignoreProcesses)
{
    private readonly Dictionary<string, string> calls = callProcesses.Select(Normalize).Where(name => name.Length > 0)
        .Distinct(StringComparer.OrdinalIgnoreCase).ToDictionary(name => name, name => name, StringComparer.OrdinalIgnoreCase);

    private readonly HashSet<string> ignored = ignoreProcesses.Select(Normalize)
        .Append("Amanu").ToHashSet(StringComparer.OrdinalIgnoreCase);

    /// <returns>The process as "Name.exe" when it counts as a call, otherwise null.</returns>
    public string? Match(string observedProcess)
    {
        var normalized = Normalize(observedProcess);
        if (normalized.Length == 0 || ignored.Contains(normalized)) return null;
        if (calls.Count == 0) return normalized + ".exe";
        return calls.TryGetValue(normalized, out var configured) ? configured + ".exe" : null;
    }

    private static string Normalize(string process)
    {
        var fileName = process.Trim().Replace('\\', '/').Split('/').LastOrDefault() ?? string.Empty;
        return fileName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? fileName[..^4] : fileName;
    }
}
