using System.Text.Json.Nodes;
using Amanu.Core.Configuration;

namespace Amanu.Core.Tests;

public sealed class AudioDeviceSettingsTests
{
    [Theory]
    [InlineData("microphone_device")]
    [InlineData("output_device")]
    public void Invalid_device_values_are_reported_and_restore_the_Windows_default(string key)
    {
        using var temporary = new TemporaryDirectory();
        var path = Path.Combine(temporary.Path, "config.json");
        File.WriteAllText(path, "{\"" + key + "\": 123}");
        var load = new AppSettingsStore(path, temporary.Path).Load();
        Assert.False(load.IsUnreadable);
        Assert.Single(load.Problems);
        Assert.Equal("", SettingsDocument.Get(SettingsDocument.ToNode(load.Settings), key)?.GetValue<string>());
    }

    [Theory]
    [InlineData("microphone_device")]
    [InlineData("output_device")]
    public void Clearing_a_persisted_device_restores_automatic_selection_after_reload(string key)
    {
        using var temporary = new TemporaryDirectory();
        var store = new AppSettingsStore(Path.Combine(temporary.Path, "config.json"), temporary.Path);
        var selected = SettingsDocument.With(store.Defaults, key, JsonValue.Create("endpoint-123"), temporary.Path);
        store.Save(selected);
        Assert.Equal("endpoint-123", SettingsDocument.Get(SettingsDocument.ToNode(store.Load().Settings), key)?.GetValue<string>());
        store.Save(SettingsDocument.With(store.Load().Settings, key, null, temporary.Path));
        Assert.Equal("", SettingsDocument.Get(SettingsDocument.ToNode(store.Load().Settings), key)?.GetValue<string>());
        Assert.DoesNotContain(key, File.ReadAllText(store.ConfigPath));
    }
}
