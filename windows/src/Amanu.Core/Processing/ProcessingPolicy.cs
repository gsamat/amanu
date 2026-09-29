using Amanu.Core.Configuration;

namespace Amanu.Core.Processing;

/// <summary>Which engines one session's transcription may use, in order.</summary>
/// <param name="Cloud">The cloud service to try first, or null.</param>
/// <param name="Local">The local model to use, alone or when the cloud cannot be reached.</param>
/// <param name="Missing">When nothing is usable, what is missing — a key or a model — in the person's words.</param>
public sealed record EnginePlan(string? Cloud, string? Local, string? Missing)
{
    public bool Usable => Cloud is not null || Local is not null;
}

public static class EngineResolver
{
    /// <summary>
    /// The plan for one session. <paramref name="engine"/> is the session's own
    /// choice when somebody asked to re-transcribe it with a particular engine,
    /// and the setting otherwise: a queue draining in the background never
    /// substitutes its own engine for the one a session asked for. A named cloud
    /// engine never falls back to this computer's model and a named local model
    /// never uploads; only <c>auto</c> has both.
    /// </summary>
    public static EnginePlan Plan(
        string engine,
        string cloudProvider,
        string localEngine,
        Func<string, bool> hasKey,
        Func<string, bool> localReady)
    {
        if (TranscriptionSettings.CloudEngines.Contains(engine))
            return hasKey(engine) ? new(engine, null, null) : new(null, null, MissingKey(engine));
        if (TranscriptionSettings.LocalEngines.Contains(engine))
            return localReady(engine) ? new(null, engine, null) : new(null, null, MissingModel(engine));

        var cloud = hasKey(cloudProvider) ? cloudProvider : null;
        var local = localReady(localEngine) ? localEngine : null;
        return cloud is null && local is null
            ? new(null, null, Localization.Localized.T(
                "Add a cloud key or download a local model in Settings.",
                "Добавьте облачный ключ или скачайте локальную модель в настройках."))
            : new(cloud, local, null);
    }

    public static string DisplayName(string engine) => engine switch
    {
        "assemblyai" => "AssemblyAI",
        "openai" => "OpenAI",
        "elevenlabs" => "ElevenLabs",
        "parakeet" => "Parakeet v3",
        "whisper" => "Whisper large-v3-turbo",
        "gigaam" => "GigaAM v3",
        _ => engine,
    };

    private static string MissingKey(string engine) => Localization.Localized.T(
        $"{DisplayName(engine)} needs a key — add it in Settings.",
        $"Для {DisplayName(engine)} нужен ключ — добавьте его в настройках.");

    private static string MissingModel(string engine) => Localization.Localized.T(
        $"{DisplayName(engine)} isn't downloaded — download it in Settings.",
        $"{DisplayName(engine)} не скачана — скачайте её в настройках.");
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
                segments.Any(other => other.Speaker?.StartsWith("them", StringComparison.OrdinalIgnoreCase) == true &&
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
