using System.Text.Json;
using System.Text.Json.Serialization;

namespace Amanu.Core.Configuration;

/// <summary>
/// Everything in <c>config.json</c>. Key names and meanings follow the macOS
/// app's config reference wherever the two platforms do the same thing, so one
/// README describes both; the Windows-only settings (the tray and taskbar icons,
/// the hook as an executable plus arguments) are named for what they are here.
/// </summary>
public sealed class AppSettings
{
    public static JsonSerializerOptions JsonOptions { get; } = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
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

    /// <summary><c>app</c>: only the call app's process tree. <c>all</c>: everything Windows plays.</summary>
    [JsonPropertyName("system_audio")]
    public string SystemAudio { get; set; } = "app";

    /// <summary>Empty follows Windows; otherwise a stable WASAPI endpoint ID.</summary>
    [JsonPropertyName("microphone_device")]
    public string MicrophoneDevice { get; set; } = "";

    [JsonPropertyName("output_device")]
    public string OutputDevice { get; set; } = "";

    [JsonPropertyName("transcript_echo_filter")]
    public bool TranscriptEchoFilter { get; set; } = true;

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

    /// <summary>Everything the file held that no property above reads — kept so a save never drops it.</summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Unknown { get; set; }

    /// <summary>
    /// In the home folder rather than in Documents: on most Windows 11 machines
    /// OneDrive backs Documents up, and recordings of meetings should not start
    /// travelling to a cloud nobody chose for them.
    /// </summary>
    public static string DefaultRecordingsDirectory(string homeDirectory) =>
        Path.Combine(homeDirectory, "Amanu Recordings");

    public static AppSettings CreateDefault(string homeDirectory) => new()
    {
        RecordingsDirectory = DefaultRecordingsDirectory(homeDirectory),
    };

    /// <summary>
    /// What Amanu runs on when the config file exists and has never been
    /// readable in this process: nothing starts by itself and nothing leaves the
    /// machine, because the file may well say so and nobody can tell.
    /// </summary>
    public static AppSettings CreateConservative(string homeDirectory)
    {
        var settings = CreateDefault(homeDirectory);
        settings.AutoRecord.Enabled = false;
        settings.Analytics = false;
        settings.Transcription.Engine = "local";
        settings.Summary.Backend = "none";
        settings.SpeakerNames.Backend = "none";
        settings.LiveTranscription.Enabled = false;
        settings.OnStop = null;
        return settings;
    }

    public AppSettings Clone() =>
        JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(this, JsonOptions), JsonOptions)!;
}

public sealed class AutoRecordSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("mic_activity")]
    public bool MicrophoneActivity { get; set; } = true;

    [JsonPropertyName("start_delay_seconds")]
    public int StartDelaySeconds { get; set; } = 3;

    [JsonPropertyName("stop_delay_seconds")]
    public int StopDelaySeconds { get; set; } = 15;

    [JsonPropertyName("min_duration_seconds")]
    public int MinimumDurationSeconds { get; set; } = 45;

    [JsonPropertyName("silence_stop_minutes")]
    public int SilenceStopMinutes { get; set; } = 10;

    [JsonPropertyName("max_duration_minutes")]
    public int MaximumDurationMinutes { get; set; } = 300;

    [JsonPropertyName("apps")]
    public List<string> CallProcesses { get; set; } = [.. DefaultCallProcesses];

    [JsonPropertyName("ignore_apps")]
    public List<string> IgnoreProcesses { get; set; } = [];

    public static readonly IReadOnlyList<string> DefaultCallProcesses =
    [
        "Zoom.exe",
        "ms-teams.exe",
        "Teams.exe",
        "Telegram.exe",
        "WhatsApp.exe",
        "Discord.exe",
        "WebexHost.exe",
        "CiscoCollabHost.exe",
        "slack.exe",
        "chrome.exe",
        "msedge.exe",
        "firefox.exe",
        "brave.exe",
        "opera.exe",
        "vivaldi.exe",
        "arc.exe",
        "Yandex.exe",
    ];
}

public sealed class TranscriptionSettings
{
    public static readonly IReadOnlyList<string> CloudEngines = ["assemblyai", "openai", "elevenlabs"];
    public static readonly IReadOnlyList<string> LocalEngines = ["parakeet", "whisper", "gigaam"];

    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// <c>auto</c>: the cloud engine when there is a key and the network answers,
    /// the local one otherwise. A cloud engine's name means that service and
    /// nothing else; a local engine's name means nothing leaves the machine.
    /// </summary>
    [JsonPropertyName("engine")]
    public string Engine { get; set; } = "auto";

    [JsonPropertyName("cloud")]
    public string Cloud { get; set; } = "assemblyai";

    [JsonPropertyName("local_engine")]
    public string LocalEngine { get; set; } = "parakeet";

    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("openai")]
    public OpenAiTranscriptionSettings OpenAi { get; set; } = new();

    [JsonPropertyName("assemblyai")]
    public AssemblyAiTranscriptionSettings AssemblyAi { get; set; } = new();
}

public sealed class OpenAiTranscriptionSettings
{
    [JsonPropertyName("model")]
    public string Model { get; set; } = "gpt-4o-transcribe-diarize";
}

public sealed class AssemblyAiTranscriptionSettings
{
    [JsonPropertyName("speech_model")]
    public string? SpeechModel { get; set; }
}

public sealed class LiveTranscriptionSettings
{
    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; }
}

public sealed class SummarySettings
{
    public static readonly IReadOnlyList<string> Backends =
        ["auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama", "none"];

    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    [JsonPropertyName("backend")]
    public string Backend { get; set; } = "auto";

    [JsonPropertyName("language")]
    public string? Language { get; set; }

    [JsonPropertyName("template")]
    public string? Template { get; set; }

    /// <summary>The Anthropic model, for the API and for the claude CLI once set.</summary>
    [JsonPropertyName("model")]
    public string? Model { get; set; }

    [JsonPropertyName("openai_model")]
    public string OpenAiModel { get; set; } = "gpt-5";

    [JsonPropertyName("openai_base_url")]
    public string OpenAiBaseUrl { get; set; } = "https://api.openai.com/v1";

    [JsonPropertyName("openai_compatible")]
    public bool? OpenAiCompatible { get; set; }

    [JsonIgnore]
    public bool UsesCompatibleOpenAi => OpenAiCompatible ??
        !(Uri.TryCreate(OpenAiBaseUrl, UriKind.Absolute, out var uri) &&
          uri.Host.Equals("api.openai.com", StringComparison.OrdinalIgnoreCase));

    // Keep the saved custom URL while the official provider is selected. An
    // unconfigured compatible provider must not fall through to OpenAI.
    [JsonIgnore]
    public string EffectiveOpenAiBaseUrl => OpenAiCompatible switch
    {
        false => "https://api.openai.com/v1",
        true when Uri.TryCreate(OpenAiBaseUrl, UriKind.Absolute, out var uri) &&
                  uri.Host.Equals("api.openai.com", StringComparison.OrdinalIgnoreCase) => "",
        _ => OpenAiBaseUrl,
    };

    [JsonPropertyName("ollama_model")]
    public string OllamaModel { get; set; } = "qwen3:8b";

    [JsonPropertyName("ollama_base_url")]
    public string OllamaBaseUrl { get; set; } = "http://127.0.0.1:11434";

    public const string DefaultAnthropicModel = "claude-opus-5";

    [JsonIgnore]
    public string AnthropicModel => string.IsNullOrWhiteSpace(Model) ? DefaultAnthropicModel : Model;
}

public sealed class SpeakerNameSettings
{
    public static readonly IReadOnlyList<string> Backends =
        ["summary", "auto", "claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama", "none"];

    [JsonPropertyName("enabled")]
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// <c>summary</c> sends the transcript wherever summaries go, and nowhere when
    /// they are off. Anything else is a choice for naming alone; <c>none</c> asks no model.
    /// </summary>
    [JsonPropertyName("backend")]
    public string Backend { get; set; } = "summary";

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
