using System.Text.Json;

namespace Amanu.Core.Processing;

public enum ProcessingStep { Off, Pending, Deferred, Failed, Done }

public sealed record SessionListItem(
    string Directory,
    string Title,
    DateTimeOffset StartedAt,
    int DurationSeconds,
    string Trigger,
    string? Engine,
    ProcessingStep Transcript,
    ProcessingStep SpeakerNames,
    ProcessingStep Summary,
    long SizeBytes,
    bool HasAudio,
    int NamedSpeakerCount = 0);

public static class SessionInventory
{
    public static async Task<IReadOnlyList<SessionListItem>> ScanAsync(
        string rootDirectory,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(rootDirectory)) return [];
        var sessions = new List<SessionListItem>();
        foreach (var directory in Directory.EnumerateDirectories(rootDirectory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var metaPath = Path.Combine(directory, "meta.json");
            if (!File.Exists(metaPath)) continue;
            try
            {
                using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(metaPath, cancellationToken).ConfigureAwait(false));
                var root = meta.RootElement;
                var started = ReadDate(root, "started_at") ?? ReadDate(root, "started") ?? Directory.GetCreationTimeUtc(directory);
                var title = ReadString(root, "title") ?? Path.GetFileName(directory);
                var transcriptPath = Path.Combine(directory, "transcript.json");
                string? engine = null;
                if (File.Exists(transcriptPath))
                {
                    using var transcript = JsonDocument.Parse(await File.ReadAllTextAsync(transcriptPath, cancellationToken).ConfigureAwait(false));
                    engine = ReadString(transcript.RootElement, "engine");
                }
                var files = Directory.EnumerateFiles(directory).ToArray();
                var hasAudio = files.Any(IsAudio);
                var namedSpeakerCount = await CountNamesAsync(Path.Combine(directory, "speakers.json"), cancellationToken).ConfigureAwait(false);
                sessions.Add(new SessionListItem(
                    directory,
                    title,
                    started,
                    ReadInt(root, "duration_seconds"),
                    ReadString(root, "trigger") ?? "manual",
                    engine,
                    Step(directory, "transcript.json", "transcribe"),
                    Step(directory, "speakers.json", "speakers"),
                    Step(directory, "summary.md", "summary"),
                    files.Sum(file => new FileInfo(file).Length),
                    hasAudio,
                    namedSpeakerCount));
            }
            catch (JsonException)
            {
                // An incomplete or hand-edited session must not hide healthy sessions.
            }
        }
        return sessions.OrderByDescending(session => session.StartedAt).ToArray();
    }

    private static ProcessingStep Step(string directory, string completedName, string prefix)
    {
        if (File.Exists(Path.Combine(directory, completedName))) return ProcessingStep.Done;
        if (File.Exists(Path.Combine(directory, $"{prefix}.off"))) return ProcessingStep.Off;
        if (File.Exists(Path.Combine(directory, $"{prefix}.failed"))) return ProcessingStep.Failed;
        if (File.Exists(Path.Combine(directory, $"{prefix}.deferred"))) return ProcessingStep.Deferred;
        return ProcessingStep.Pending;
    }

    private static bool IsAudio(string path) => new[] { ".wav", ".m4a", ".mp3", ".flac", ".ogg" }
        .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    private static string? ReadString(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int ReadInt(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.TryGetInt32(out var result) ? result : 0;

    private static DateTimeOffset? ReadDate(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.TryGetDateTimeOffset(out var result) ? result : null;

    private static async Task<int> CountNamesAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return 0;
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false));
            return json.RootElement.TryGetProperty("names", out var names) && names.ValueKind == JsonValueKind.Object
                ? names.EnumerateObject().Count()
                : 0;
        }
        catch (JsonException) { return 0; }
    }
}
