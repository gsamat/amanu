using Amanu.Core.Configuration;

namespace Amanu.Core.Tests;

public sealed class AppSettingsStoreTests
{
    [Fact]
    public void LoadCreatesDefaultsWhenConfigDoesNotExist()
    {
        using var temporary = new TemporaryDirectory();
        var configPath = Path.Combine(temporary.Path, "config.json");
        var store = new AppSettingsStore(configPath, @"C:\Users\Beta\Documents");

        var settings = store.Load();

        Assert.Equal(@"C:\Users\Beta\Documents\Amanu Recordings", settings.RecordingsDirectory);
        Assert.True(settings.AutoRecord.Enabled);
        Assert.True(File.Exists(configPath));
    }

    [Fact]
    public void LoadQuarantinesMalformedConfigAndRestoresDefaults()
    {
        using var temporary = new TemporaryDirectory();
        var configPath = Path.Combine(temporary.Path, "config.json");
        File.WriteAllText(configPath, "{ definitely not json");
        var store = new AppSettingsStore(configPath, @"C:\Users\Beta\Documents");

        var settings = store.Load();

        Assert.True(settings.StartAtLogin);
        Assert.Single(Directory.GetFiles(temporary.Path, "config.invalid-*.json"));
        Assert.True(File.Exists(configPath));
    }

    [Fact]
    public void SaveAndLoadRoundTripsSettings()
    {
        using var temporary = new TemporaryDirectory();
        var configPath = Path.Combine(temporary.Path, "config.json");
        var store = new AppSettingsStore(configPath, @"C:\Users\Beta\Documents");
        var expected = new AppSettings
        {
            RecordingsDirectory = @"D:\Recordings",
            KeepAudio = true,
            StartAtLogin = false,
            AutoRecord = new AutoRecordSettings { StartDelaySeconds = 4 },
        };

        store.Save(expected);
        var actual = store.Load();

        Assert.Equal(expected.RecordingsDirectory, actual.RecordingsDirectory);
        Assert.True(actual.KeepAudio);
        Assert.False(actual.StartAtLogin);
        Assert.Equal(4, actual.AutoRecord.StartDelaySeconds);
    }
}
