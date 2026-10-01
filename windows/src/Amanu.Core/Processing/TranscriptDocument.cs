using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Amanu.Core.Processing;

public sealed record TranscriptSegment(
    [property: JsonPropertyName("start_ms")] long StartMs,
    [property: JsonPropertyName("end_ms")] long EndMs,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("speaker")] string? Speaker = null);

public sealed record TranscriptDocument(
    [property: JsonPropertyName("engine")] string Engine,
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("created_at")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("segments")] IReadOnlyList<TranscriptSegment> Segments);

public static class TranscriptWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    public static async Task WriteAsync(
        string directory,
        string title,
        TranscriptDocument transcript,
        IReadOnlyDictionary<string, string>? speakerNames = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(directory);
        var markdown = RenderMarkdown(title, transcript, speakerNames);
        await WriteAtomicallyAsync(Path.Combine(directory, "transcript.md"), markdown, cancellationToken)
            .ConfigureAwait(false);
        await WriteAtomicallyAsync(
                Path.Combine(directory, "transcript.json"),
                JsonSerializer.Serialize(transcript, JsonOptions),
                cancellationToken)
            .ConfigureAwait(false);
    }

    public static string RenderMarkdown(
        string title,
        TranscriptDocument transcript,
        IReadOnlyDictionary<string, string>? speakerNames = null)
    {
        var result = new StringBuilder()
            .Append("# ").AppendLine(title)
            .AppendLine()
            .Append("engine: ").Append(transcript.Engine).Append(" (").Append(transcript.Model).AppendLine(")");
        if (speakerNames is { Count: > 0 })
        {
            result.Append("speakers: ").AppendLine(string.Join(", ", speakerNames.Select(pair => $"{pair.Key} → {pair.Value}")));
        }
        result.AppendLine();
        foreach (var segment in transcript.Segments)
        {
            var time = TimeSpan.FromMilliseconds(Math.Max(0, segment.StartMs));
            var timestamp = time.TotalHours >= 1
                ? time.ToString("h\\:mm\\:ss", CultureInfo.InvariantCulture)
                : time.ToString("m\\:ss", CultureInfo.InvariantCulture);
            var speaker = segment.Speaker is null
                ? "speaker"
                : speakerNames?.GetValueOrDefault(segment.Speaker) ?? segment.Speaker;
            result.Append("**[").Append(timestamp).Append("] ").Append(speaker).Append(":** ")
                .AppendLine(segment.Text.Trim()).AppendLine();
        }
        return result.ToString();
    }

    private static async Task WriteAtomicallyAsync(string path, string contents, CancellationToken cancellationToken)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllTextAsync(temporary, contents, Encoding.UTF8, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
