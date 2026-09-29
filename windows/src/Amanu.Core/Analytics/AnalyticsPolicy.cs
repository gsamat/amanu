namespace Amanu.Core.Analytics;

public static class AnalyticsPolicy
{
    public static IReadOnlySet<string> Events { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "installed", "version_seen", "settings_opened", "recording_started", "recording_start_failed",
        "recording_finished", "transcript_finished", "transcript_fallback", "transcript_failed",
        "summary_finished", "summary_failed", "speaker_names_finished", "speaker_names_failed",
        "model_download_started", "model_download_finished", "model_download_failed", "artifact_opened",
        "session_interrupted", "setting_changed",
    };

    private static readonly IReadOnlySet<string> PropertyKeys = new HashSet<string>(StringComparer.Ordinal)
    {
        "surface", "trigger", "duration_bucket", "live_used", "system_audio", "engine", "backend", "model",
        "fallback_used", "from_engine", "to_engine", "component", "outcome", "asset", "artifact", "reason",
        "key", "value", "analytics_schema_version", "app_version", "windows_version", "arch",
        "interface_language", "live_transcription", "speaker_names", "auto_record", "transcription_engine",
        "transcription_enabled", "transcription_cloud_provider", "summary_backend", "summary_enabled",
        "speaker_names_backend", "keep_audio",
    };

    private static readonly IReadOnlyDictionary<string, IReadOnlySet<string>> Choices =
        new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal)
        {
            ["engine"] = Set("auto", "parakeet", "gigaam", "whisper", "openai", "assemblyai", "local"),
            ["from_engine"] = Set("auto", "parakeet", "gigaam", "whisper", "openai", "assemblyai", "local"),
            ["to_engine"] = Set("auto", "parakeet", "gigaam", "whisper", "openai", "assemblyai", "local"),
            ["transcription_engine"] = Set("auto", "cloud", "local"),
            ["backend"] = Set("auto", "anthropic", "openai", "ollama"),
            ["summary_backend"] = Set("auto", "anthropic", "openai", "ollama"),
            ["speaker_names_backend"] = Set("auto", "anthropic", "openai", "ollama"),
            ["transcription_cloud_provider"] = Set("assemblyai", "openai"),
            ["trigger"] = Set("manual", "mic-activity", "import"),
            ["reason"] = Set("no_network", "no_key", "no_model", "usage_limit", "audio_missing", "audio_too_short", "refused", "timed_out", "http_error", "quit", "unknown"),
            ["outcome"] = Set("deferred", "gave_up"),
            ["artifact"] = Set("recordings_window", "recordings_root", "session_folder"),
            ["asset"] = Set("runtime", "parakeet-v3", "gigaam-v3", "whisper-large-v3-turbo"),
            ["model"] = Set("default", "universal-3-pro", "gpt-4o-transcribe-diarize", "parakeet-v3", "gigaam-v3", "whisper-large-v3-turbo", "gpt-5", "claude-opus-5", "qwen3:8b", "custom", "custom-local", "unknown"),
            ["surface"] = Set("app", "cli"),
            ["duration_bucket"] = Set("under_5m", "5_15m", "15_30m", "30_60m", "1_2h", "over_2h"),
            ["interface_language"] = Set("auto", "en", "ru"),
            ["auto_record"] = Set("off", "mic"),
        };

    public static string DurationBucket(double seconds) => seconds switch
    {
        < 300 => "under_5m",
        < 900 => "5_15m",
        < 1_800 => "15_30m",
        < 3_600 => "30_60m",
        < 7_200 => "1_2h",
        _ => "over_2h",
    };

    public static IReadOnlyDictionary<string, object> Sanitize(IReadOnlyDictionary<string, object?> properties)
    {
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        foreach (var pair in properties)
        {
            if (!PropertyKeys.Contains(pair.Key) || pair.Value is null) continue;
            if (Choices.TryGetValue(pair.Key, out var allowed))
            {
                result[pair.Key] = pair.Value is string text && allowed.Contains(text) ? text : "custom";
                continue;
            }
            if (pair.Value is string or bool or int or long or double) result[pair.Key] = pair.Value;
        }
        return result;
    }

    private static IReadOnlySet<string> Set(params string[] values) => new HashSet<string>(values, StringComparer.Ordinal);
}
