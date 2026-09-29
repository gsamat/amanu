namespace Amanu.Core.Processing;

public static class EngineSelector
{
    public static string Select(string preference, bool hasCloudKey, bool localSupported) =>
        preference.Trim().ToLowerInvariant() switch
        {
            "cloud" => hasCloudKey ? "cloud" : "unavailable",
            "local" => localSupported ? "local" : hasCloudKey ? "cloud" : "unavailable",
            _ => hasCloudKey && localSupported ? "cloud-or-local"
                : hasCloudKey ? "cloud"
                : localSupported ? "local"
                : "unavailable",
        };
}

public static class SpeakerNameValidator
{
    public static bool Accept(string confidence, string quote, string transcript)
    {
        if (!confidence.Equals("high", StringComparison.OrdinalIgnoreCase)) return false;
        if (quote.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length < 2) return false;
        return transcript.Contains(quote, StringComparison.OrdinalIgnoreCase);
    }
}

public static class SummaryChunker
{
    public static IReadOnlyList<string> Split(string text, int maximumCharacters = 60_000)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumCharacters, 1);
        if (text.Length <= maximumCharacters) return [text];
        var chunks = new List<string>();
        var position = 0;
        while (position < text.Length)
        {
            var length = Math.Min(maximumCharacters, text.Length - position);
            if (position + length < text.Length)
            {
                var newline = text.LastIndexOf('\n', position + length - 1, length);
                if (newline >= position) length = newline - position + 1;
            }
            chunks.Add(text.Substring(position, length));
            position += length;
        }
        return chunks;
    }
}

public static class TranscriptEchoFilter
{
    public static IReadOnlyList<TranscriptSegment> Filter(IReadOnlyList<TranscriptSegment> segments)
    {
        var result = new List<TranscriptSegment>();
        foreach (var segment in segments)
        {
            if (segment.Speaker?.Equals("me", StringComparison.OrdinalIgnoreCase) == true &&
                segments.Any(other => other.Speaker?.Equals("them", StringComparison.OrdinalIgnoreCase) == true &&
                    Overlaps(segment, other) && SameWords(segment.Text, other.Text)))
                continue;
            result.Add(segment);
        }
        return result;
    }

    private static bool Overlaps(TranscriptSegment left, TranscriptSegment right) =>
        Math.Max(left.StartMs, right.StartMs) <= Math.Min(left.EndMs, right.EndMs) + 500;

    private static bool SameWords(string left, string right)
    {
        static string Normalize(string value) => new(value.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        var a = Normalize(left);
        var b = Normalize(right);
        if (a.Length < 6 || b.Length < 6) return false;
        return a == b || (Math.Min(a.Length, b.Length) >= Math.Max(a.Length, b.Length) * 0.8 &&
                          (a.Contains(b, StringComparison.Ordinal) || b.Contains(a, StringComparison.Ordinal)));
    }
}
