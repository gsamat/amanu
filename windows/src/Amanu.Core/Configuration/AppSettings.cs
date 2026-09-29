using System.Text.Json;
using System.Text.Json.Serialization;

namespace Amanu.Core.Configuration;

public sealed class AppSettings
{
    public static JsonSerializerOptions JsonOptions { get; } = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    [JsonPropertyName("recordings_dir")]
    public string RecordingsDirectory { get; set; } = string.Empty;

    [JsonPropertyName("keep_audio")]
    public bool KeepAudio { get; set; }

    [JsonPropertyName("analytics")]
    public bool Analytics { get; set; } = true;

    [JsonPropertyName("interface_language")]
    public string InterfaceLanguage { get; set; } = "auto";

    [JsonPropertyName("user_name")]
    public string? UserName { get; set; }

    [JsonPropertyName("auto_record")]
    public AutoRecordSettings AutoRecord { get; set; } = new();

    [JsonPropertyName("transcription")]
    public TranscriptionSettings Transcription { get; set; } = new();

    [JsonPropertyName("live_transcription")]
    public LiveTranscriptionSettings LiveTranscription { get; set; } = new();

    [JsonPropertyName("summary")]
    public SummarySettings Summary { get; set; } = new();

    [JsonPropertyName("speaker_names")]
    public SpeakerNameSettings SpeakerNames { get; set; } = new();

    [JsonPropertyName("start_at_login")]
    public bool StartAtLogin { get; set; } = true;

    [JsonPropertyName("tray_icon")]
    public bool TrayIcon { get; set; } = true;

    [JsonPropertyName("taskbar_icon")]
    public bool TaskbarIcon { get; set; } = true;

    [JsonPropertyName("on_stop")]
    public CommandHook? OnStop { get; set; }

    public static AppSettings CreateDefault(string documentsDirectory) => new()
    {
        RecordingsDirectory = documentsDirectory.TrimEnd('\\', '/') + "\\Amanu Recordings",
    };
}

public sealed class AutoRecordSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("mic_activity")]
    public bool MicrophoneActivity { get; set; } = true;

    [JsonPropertyName("start_delay_seconds")]
    public int StartDelaySeconds { get; set; } = 12;

    [JsonPropertyName("stop_delay_seconds")]
    public int StopDelaySeconds { get; set; } = 15;

    [JsonPropertyName("min_duration_seconds")]
    public int MinimumDurationSeconds { get; set; } = 45;

    [JsonPropertyName("silence_stop_minutes")]
    public int SilenceStopMinutes { get; set; } = 10;

    [JsonPropertyName("max_duration_minutes")]
    public int MaximumDurationMinutes { get; set; } = 300;

    [JsonPropertyName("apps")]
    public List<string> CallProcesses { get; set; } =
    [
        "Zoom.exe",
        "ms-teams.exe",
        "Teams.exe",
        "Telegram.exe",
        "WhatsApp.exe",
        "Discord.exe",
        "WebexHost.exe",
        "slack.exe",
        "chrome.exe",
        "msedge.exe",
        "firefox.exe",
    ];

    [JsonPropertyName("ignore_apps")]
    public List<string> IgnoreProcesses { get; set; } = [];
}

public sealed class TranscriptionSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("engine")]
    public string Engine { get; set; } = "auto";

    [JsonPropertyName("cloud")]
    public string Cloud { get; set; } = "assemblyai";

    [JsonPropertyName("local_engine")]
    public string LocalEngine { get; set; } = "parakeet";

    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("openai_model")]
    public string OpenAiModel { get; set; } = "gpt-4o-transcribe-diarize";

    [JsonPropertyName("local_model_directory")]
    public string? LocalModelDirectory { get; set; }

    [JsonPropertyName("echo_filter")]
    public bool EchoFilter { get; set; } = true;

    [JsonPropertyName("offline_echo_cancellation")]
    public bool OfflineEchoCancellation { get; set; } = true;
}

public sealed class LiveTranscriptionSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }
}

public sealed class SummarySettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("backend")]
    public string Backend { get; set; } = "auto";

    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("template")]
    public string? Template { get; set; }

    [JsonPropertyName("openai_model")]
    public string OpenAiModel { get; set; } = "gpt-5";

    [JsonPropertyName("openai_base_url")]
    public string OpenAiBaseUrl { get; set; } = "https://api.openai.com/v1";

    [JsonPropertyName("anthropic_model")]
    public string AnthropicModel { get; set; } = "claude-opus-5";

    [JsonPropertyName("ollama_model")]
    public string OllamaModel { get; set; } = "qwen3:8b";

    [JsonPropertyName("ollama_url")]
    public string OllamaUrl { get; set; } = "http://127.0.0.1:11434";
}

public sealed class SpeakerNameSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("backend")]
    public string Backend { get; set; } = "auto";

    [JsonPropertyName("model")]
    public string? Model { get; set; }
}

public sealed class CommandHook
{
    [JsonPropertyName("executable")]
    public string Executable { get; set; } = string.Empty;

    [JsonPropertyName("arguments")]
    public List<string> Arguments { get; set; } = [];
}
