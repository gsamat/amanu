using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Amanu.Core.Sessions;

public enum SessionTrigger
{
    Manual,
    MicrophoneActivity,
}

public sealed record SessionHandle(
    string Directory,
    string MicrophoneTrack,
    string SystemTrack,
    DateTimeOffset StartedAt,
    string? Title,
    SessionTrigger Trigger,
    string? ProcessFamily);

public sealed partial class SessionStore(string rootDirectory, int processId)
{
    private const string MarkerName = ".recording.json";
    private const string MetaName = "meta.json";

    public SessionHandle Start(
        DateTimeOffset startedAt,
        string? title,
        SessionTrigger trigger,
        string? processFamily)
    {
        Directory.CreateDirectory(rootDirectory);
        var prefix = startedAt.ToString("yyyy.MM.dd-HHmm", CultureInfo.InvariantCulture);
        var suffix = SanitizeTitle(title);
        var baseName = suffix.Length == 0 ? prefix : $"{prefix} {suffix}";
        var directory = UniqueDirectory(baseName);
        Directory.CreateDirectory(directory);

        var handle = new SessionHandle(
            directory,
            Path.Combine(directory, "mic.wav"),
            Path.Combine(directory, "system.wav"),
            startedAt,
            title,
            trigger,
            processFamily);

        WriteJsonAtomically(Path.Combine(directory, MarkerName), Marker(handle));
        return handle;
    }

    public void Complete(
        SessionHandle session,
        DateTimeOffset endedAt,
        string stopReason,
        int micOffsetMs,
        int systemOffsetMs,
        int pausedSeconds = 0)
    {
        WriteJsonAtomically(
            Path.Combine(session.Directory, MetaName),
            Meta(session, endedAt, stopReason, micOffsetMs, systemOffsetMs, pausedSeconds));
        File.Delete(Path.Combine(session.Directory, MarkerName));
    }

    public IReadOnlyList<string> RecoverInterrupted(
        DateTimeOffset now,
        Func<int, bool> processIsAlive)
    {
        if (!Directory.Exists(rootDirectory))
        {
            return [];
        }

        var recovered = new List<string>();
        foreach (var directory in Directory.EnumerateDirectories(rootDirectory))
        {
            var markerPath = Path.Combine(directory, MarkerName);
            if (!File.Exists(markerPath))
            {
                continue;
            }

            if (File.Exists(Path.Combine(directory, MetaName)))
            {
                File.Delete(markerPath);
                continue;
            }

            RecordingMarker? marker;
            try
            {
                marker = JsonSerializer.Deserialize<RecordingMarker>(
                    File.ReadAllText(markerPath), JsonOptions);
            }
            catch (JsonException)
            {
                continue;
            }

            if (marker is null || processIsAlive(marker.Pid))
            {
                continue;
            }

            var session = new SessionHandle(
                directory,
                Path.Combine(directory, marker.Files.Mic),
                Path.Combine(directory, marker.Files.System),
                marker.Started,
                marker.Title,
                ParseTrigger(marker.Trigger),
                marker.ProcessFamily);
            Complete(session, now, "interrupted", 0, 0);
            recovered.Add(directory);
        }

        return recovered;
    }

    private string UniqueDirectory(string baseName)
    {
        var candidate = Path.Combine(rootDirectory, baseName);
        for (var suffix = 2; Directory.Exists(candidate); suffix++)
        {
            candidate = Path.Combine(rootDirectory, $"{baseName}-{suffix}");
        }
        return candidate;
    }

    private object Marker(SessionHandle session) => new Dictionary<string, object?>
    {
        ["pid"] = processId,
        ["started"] = session.StartedAt,
        ["title"] = session.Title,
        ["trigger"] = TriggerName(session.Trigger),
        ["process_family"] = session.ProcessFamily,
        ["files"] = new Dictionary<string, string>
        {
            ["mic"] = Path.GetFileName(session.MicrophoneTrack),
            ["system"] = Path.GetFileName(session.SystemTrack),
        },
    };

    private static object Meta(
        SessionHandle session,
        DateTimeOffset endedAt,
        string stopReason,
        int micOffsetMs,
        int systemOffsetMs,
        int pausedSeconds) => new Dictionary<string, object?>
    {
        ["started"] = session.StartedAt,
        ["ended"] = endedAt,
        ["duration_seconds"] = Math.Max(0, (int)(endedAt - session.StartedAt).TotalSeconds),
        ["title"] = session.Title,
        ["trigger"] = TriggerName(session.Trigger),
        ["stop_reason"] = stopReason,
        ["paused_seconds"] = pausedSeconds,
        ["platform"] = "windows",
        ["process_family"] = session.ProcessFamily,
        ["system_audio"] = session.ProcessFamily is null ? "all" : $"app: {session.ProcessFamily}",
        ["files"] = new Dictionary<string, string>
        {
            ["mic"] = Path.GetFileName(session.MicrophoneTrack),
            ["system"] = Path.GetFileName(session.SystemTrack),
        },
        ["start_offset_ms"] = new Dictionary<string, int>
        {
            ["mic"] = micOffsetMs,
            ["system"] = systemOffsetMs,
        },
    };

    private static void WriteJsonAtomically(string path, object value)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value, JsonOptions));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private static string SanitizeTitle(string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            return string.Empty;
        }

        var sanitized = InvalidFileNameCharacters().Replace(title, " ");
        sanitized = Whitespace().Replace(sanitized, " ").Trim().TrimEnd('.', ' ');
        return sanitized.Length <= 80 ? sanitized : sanitized[..80].TrimEnd();
    }

    private static string TriggerName(SessionTrigger trigger) => trigger switch
    {
        SessionTrigger.Manual => "manual",
        SessionTrigger.MicrophoneActivity => "mic-activity",
        _ => throw new ArgumentOutOfRangeException(nameof(trigger), trigger, null),
    };

    private static SessionTrigger ParseTrigger(string trigger) => trigger switch
    {
        "mic-activity" => SessionTrigger.MicrophoneActivity,
        _ => SessionTrigger.Manual,
    };

    private static JsonSerializerOptions JsonOptions { get; } = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    [GeneratedRegex("[<>:\"/\\\\|?*\\x00-\\x1F]", RegexOptions.CultureInvariant)]
    private static partial Regex InvalidFileNameCharacters();

    [GeneratedRegex("\\s+", RegexOptions.CultureInvariant)]
    private static partial Regex Whitespace();

    private sealed record RecordingMarker(
        int Pid,
        DateTimeOffset Started,
        string? Title,
        string Trigger,
        string? ProcessFamily,
        TrackFiles Files);

    private sealed record TrackFiles(string Mic, string System);
}
