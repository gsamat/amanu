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
