using System.Text.Json;

namespace Amanu.Core.Processing;

public enum ProcessingStep { Off, Pending, Deferred, Failed, Done, Stale, Recording }

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
    int NamedSpeakerCount = 0,
    int SpeakerCount = 0,
    string? Problem = null);

/// <summary>What is in the recordings folder, read from the files each session leaves.</summary>
public static class SessionInventory
{
    /// <summary>
    /// The one answer to "which folders are sessions": not hidden (an import still
    /// being copied lives under a dot-name), and holding meta.json or the marker of
    /// a recording in progress.
    /// </summary>
    public static bool IsSession(string directory) =>
        !Path.GetFileName(directory).StartsWith('.')
        && (File.Exists(Path.Combine(directory, "meta.json")) || File.Exists(Path.Combine(directory, ".recording.json")));

    public static async Task<IReadOnlyList<SessionListItem>> ScanAsync(string rootDirectory, CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(rootDirectory)) return [];
        var sessions = new List<SessionListItem>();
        foreach (var directory in Directory.EnumerateDirectories(rootDirectory).Where(IsSession))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                sessions.Add(await ReadAsync(directory, cancellationToken).ConfigureAwait(false));
            }
            catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
            {
                // An incomplete or hand-edited session must not hide healthy ones.
            }
        }
        return sessions.OrderByDescending(session => session.StartedAt).ToArray();
    }

    public static async Task<SessionListItem> ReadAsync(string directory, CancellationToken cancellationToken = default)
    {
        var metaPath = Path.Combine(directory, "meta.json");
        var recording = !File.Exists(metaPath);
        using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(recording ? Path.Combine(directory, ".recording.json") : metaPath, cancellationToken).ConfigureAwait(false));
        var root = meta.RootElement;
        var started = ReadDate(root, "started_at") ?? ReadDate(root, "started") ?? Directory.GetCreationTime(directory);
        var title = ReadString(root, "title") ?? Path.GetFileName(directory);

        string? engine = null;
        var labels = new HashSet<string>(StringComparer.Ordinal);
        var transcriptPath = Path.Combine(directory, "transcript.json");
        if (File.Exists(transcriptPath))
        {
            using var transcript = JsonDocument.Parse(await File.ReadAllTextAsync(transcriptPath, cancellationToken).ConfigureAwait(false));
            engine = ReadString(transcript.RootElement, "engine");
            if (transcript.RootElement.TryGetProperty("segments", out var segments) && segments.ValueKind == JsonValueKind.Array)
                foreach (var segment in segments.EnumerateArray())
                    if (ReadString(segment, "speaker") is { } label) labels.Add(label);
        }
        var names = await NamesAsync(Path.Combine(directory, "speakers.json"), cancellationToken).ConfigureAwait(false);
        var files = Directory.EnumerateFiles(directory).ToArray();

        var transcriptStep = recording ? ProcessingStep.Recording : Step(directory, "transcript.json", "transcribe");
        var summaryStep = Step(directory, "summary.md", "summary");
        if (summaryStep == ProcessingStep.Done && File.Exists(Path.Combine(directory, "summary.stale"))) summaryStep = ProcessingStep.Stale;
        var problem = new[] { "transcribe.failed", "transcribe.deferred", "summary.failed", "summary.deferred", "speakers.failed", "speakers.deferred" }
            .Select(name => Path.Combine(directory, name)).Where(File.Exists)
            .Select(path => File.ReadAllText(path).Trim()).FirstOrDefault(text => text.Length > 0);

        return new SessionListItem(
            directory,
            title,
            started,
            ReadInt(root, "duration_seconds"),
            ReadString(root, "trigger") ?? "manual",
            engine,
            transcriptStep,
            Step(directory, "speakers.json", "speakers"),
            summaryStep,
            files.Sum(file => new FileInfo(file).Length),
            files.Any(IsAudio),
            labels.Count(names.Contains),
            labels.Count,
            problem);
    }

    private static ProcessingStep Step(string directory, string completedName, string prefix)
    {
        if (File.Exists(Path.Combine(directory, $"{prefix}.failed"))) return ProcessingStep.Failed;
        if (File.Exists(Path.Combine(directory, completedName))) return ProcessingStep.Done;
        if (File.Exists(Path.Combine(directory, $"{prefix}.off"))) return ProcessingStep.Off;
        if (File.Exists(Path.Combine(directory, $"{prefix}.deferred"))) return ProcessingStep.Deferred;
        return ProcessingStep.Pending;
    }

    private static bool IsAudio(string path) => new[] { ".wav", ".m4a", ".mp3", ".flac", ".ogg", ".mp4", ".aac", ".mov", ".mkv", ".webm" }
        .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)
        && !Path.GetFileName(path).StartsWith('.');

    private static string? ReadString(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static int ReadInt(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.TryGetInt32(out var result) ? result : 0;

    private static DateTimeOffset? ReadDate(JsonElement element, string property) =>
        element.TryGetProperty(property, out var value) && value.TryGetDateTimeOffset(out var result) ? result : null;

    private static async Task<HashSet<string>> NamesAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return [];
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false));
            return json.RootElement.TryGetProperty("names", out var names) && names.ValueKind == JsonValueKind.Object
                ? names.EnumerateObject().Where(pair => pair.Value.ValueKind == JsonValueKind.String && pair.Value.GetString()!.Length > 0)
                    .Select(pair => pair.Name).ToHashSet(StringComparer.Ordinal)
                : [];
        }
        catch (JsonException) { return []; }
    }
}
