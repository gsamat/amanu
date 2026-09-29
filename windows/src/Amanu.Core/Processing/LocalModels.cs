using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Amanu.Core.Processing;

public sealed record DownloadArtifact(string Url, string Sha256, long Size, string FileName);

public static class ModelCatalog
{
    public static IReadOnlyDictionary<string, DownloadArtifact> Models { get; } =
        new Dictionary<string, DownloadArtifact>(StringComparer.OrdinalIgnoreCase)
        {
            ["parakeet"] = new(
                "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/main/parakeet-tdt-0.6b-v3-Q8_0.gguf",
                "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7",
                739_508_576,
                "parakeet-tdt-0.6b-v3-Q8_0.gguf"),
            ["gigaam"] = new(
                "https://huggingface.co/handy-computer/gigaam-v3-ctc-gguf/resolve/main/gigaam-v3-ctc-Q8_0.gguf",
                "71e5c82890e9e243a6bd7575f129f5d1bd2c3ca3ae79aab75cfb1a6934c6a62b",
                271_803_328,
                "gigaam-v3-ctc-Q8_0.gguf"),
            ["whisper"] = new(
                "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/main/whisper-large-v3-turbo-Q8_0.gguf",
                "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183",
                886_381_760,
                "whisper-large-v3-turbo-Q8_0.gguf"),
        };
}

public sealed record LocalCliResult(string File, string Text, IReadOnlyList<TranscriptSegment> Segments);

public static class LocalCliResultParser
{
    public static LocalCliResult Parse(string jsonl)
    {
        var line = jsonl.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Last();
        // transcribe.cpp 0.1.3 writes Windows backslashes in `file` without JSON escaping.
        // Amanu does not use that field, so discard it before parsing the transcript.
        line = Regex.Replace(line, "\"file\"\\s*:\\s*\"[^\"]*\"", "\"file\":\"\"");
        var raw = JsonSerializer.Deserialize<RawResult>(line, new JsonSerializerOptions(JsonSerializerDefaults.Web))
                  ?? throw new JsonException("The local transcription result was empty.");
        return new LocalCliResult(raw.File ?? string.Empty, raw.Text ?? string.Empty,
            raw.Segments?.Select(segment => new TranscriptSegment(
                segment.StartMs, segment.EndMs, segment.Text ?? string.Empty, segment.Speaker)).ToArray() ?? []);
    }

    private sealed record RawResult(
        string? File,
        string? Text,
        IReadOnlyList<RawSegment>? Segments);

    private sealed record RawSegment(
        [property: JsonPropertyName("t0_ms")] long StartMs,
        [property: JsonPropertyName("t1_ms")] long EndMs,
        [property: JsonPropertyName("speaker_id")] string? Speaker,
        string? Text);
}

public sealed record TimedWord(long StartMs, long EndMs, string Text);

/// <summary>
/// Parakeet's words, as the macOS app gets them from FluidAudio's token timings.
/// transcribe.cpp computes them too but its `--batch-jsonl` leaves them out (as of
/// v0.2.4), so they are read from the CLI's plain output for one file: a
/// `words: N` line and then N lines of `  [ 20.72 ->  20.96] word`.
/// </summary>
public static partial class LocalCliWords
{
    public static IReadOnlyList<TimedWord> Parse(string output)
    {
        var lines = output.Split('\n');
        var header = Array.FindIndex(lines, line => line.StartsWith("words: ", StringComparison.Ordinal));
        if (header < 0 || !int.TryParse(lines[header]["words: ".Length..].Trim(), out var count)) return [];
        var words = new List<TimedWord>(count);
        for (var index = header + 1; index < lines.Length && words.Count < count; index++)
        {
            var match = WordLine().Match(lines[index].TrimEnd('\r'));
            if (!match.Success) break;
            var text = match.Groups[3].Value.Trim();
            if (text.Length == 0) continue;
            words.Add(new TimedWord(Milliseconds(match.Groups[1].Value), Milliseconds(match.Groups[2].Value), text));
        }
        return words;
    }

    /// <summary>
    /// Readable segments, grouped as macOS groups them (ParakeetEngine.segments):
    /// a new one after sentence-ending punctuation, before a gap of more than a
    /// second, and after sixty words so a run-on speaker still wraps.
    /// </summary>
    public static IReadOnlyList<TranscriptSegment> Segments(IReadOnlyList<TimedWord> words)
    {
        var segments = new List<TranscriptSegment>();
        var current = new List<TimedWord>();
        void Flush()
        {
            if (current.Count == 0) return;
            segments.Add(new TranscriptSegment(current[0].StartMs, current[^1].EndMs, string.Join(' ', current.Select(word => word.Text)), null));
            current.Clear();
        }
        foreach (var word in words)
        {
            if (current.Count > 0 && word.StartMs - current[^1].EndMs > 1000) Flush();
            current.Add(word);
            if (word.Text.EndsWith('.') || word.Text.EndsWith('?') || word.Text.EndsWith('!') || current.Count >= 60) Flush();
        }
        Flush();
        return segments;
    }

    /// <summary>The `text:` line, empty when the CLI says `(empty)` or printed none.</summary>
    public static string FullText(string output)
    {
        var line = output.Split('\n').FirstOrDefault(line => line.StartsWith("text: ", StringComparison.Ordinal));
        var text = line?["text: ".Length..].Trim() ?? string.Empty;
        return text == "(empty)" ? string.Empty : text;
    }

    private static long Milliseconds(string seconds) =>
        (long)Math.Round(double.Parse(seconds, System.Globalization.CultureInfo.InvariantCulture) * 1000);

    [GeneratedRegex(@"^\s*\[\s*(-?\d+(?:\.\d+)?)\s*->\s*(-?\d+(?:\.\d+)?)\]\s?(.*)$")]
    private static partial Regex WordLine();
}
