using System.Text.Json;
using Amanu.Core.Configuration;

namespace Amanu.Core.Tests;

public sealed class AppSettingsTests
{
    [Fact]
    public void Windows_defaults_keep_the_product_contract_without_calendar_settings()
    {
        var settings = AppSettings.CreateDefault(@"C:\Users\Samat\Documents");

        Assert.Equal(Path.Combine(@"C:\Users\Samat\Documents", "Amanu Recordings"), settings.RecordingsDirectory);
        Assert.Equal("summary", settings.SpeakerNames.Backend);
        Assert.True(settings.AutoRecord.Enabled);
        Assert.True(settings.AutoRecord.MicrophoneActivity);
        Assert.Contains("Zoom.exe", settings.AutoRecord.CallProcesses);
        Assert.Equal("auto", settings.Transcription.Engine);
        Assert.Equal("parakeet", settings.Transcription.LocalEngine);
        Assert.True(settings.Summary.Enabled);

        var json = JsonSerializer.Serialize(settings, AppSettings.JsonOptions);
        Assert.DoesNotContain("calendar", json, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Existing_shared_setting_names_deserialize_and_unknown_fields_are_ignored()
    {
        const string json = """
            {
              "recordings_dir": "D:\\Meetings",
              "keep_audio": true,
              "calendar": true,
              "auto_record": {
                "enabled": false,
                "start_delay_seconds": 7,
                "apps": ["custom-call.exe"]
              },
              "transcription": { "engine": "openai", "language": "ru" },
              "summary": { "enabled": false, "backend": "ollama" }
            }
            """;

        var settings = JsonSerializer.Deserialize<AppSettings>(json, AppSettings.JsonOptions)!;

        Assert.Equal(@"D:\Meetings", settings.RecordingsDirectory);
        Assert.True(settings.KeepAudio);
        Assert.False(settings.AutoRecord.Enabled);
        Assert.Equal(7, settings.AutoRecord.StartDelaySeconds);
        Assert.Equal(["custom-call.exe"], settings.AutoRecord.CallProcesses);
        Assert.Equal("openai", settings.Transcription.Engine);
        Assert.Equal("ru", settings.Transcription.Language);
        Assert.False(settings.Summary.Enabled);
        Assert.Equal("ollama", settings.Summary.Backend);
    }
}
