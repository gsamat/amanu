using System.Text.Json;

namespace Amanu.Core.Configuration;

public sealed class AppSettingsStore(string configPath, string documentsDirectory)
{
    public AppSettings Load()
    {
        if (!File.Exists(configPath))
        {
            var defaults = AppSettings.CreateDefault(documentsDirectory);
            Save(defaults);
            return defaults;
        }

        try
        {
            return JsonSerializer.Deserialize<AppSettings>(
                       File.ReadAllText(configPath), AppSettings.JsonOptions)
                   ?? RestoreDefaults();
        }
        catch (JsonException)
        {
            var directory = Path.GetDirectoryName(configPath)!;
            var quarantine = Path.Combine(
                directory,
                $"config.invalid-{DateTimeOffset.UtcNow:yyyyMMddHHmmssfff}.json");
            File.Move(configPath, quarantine);
            return RestoreDefaults();
        }
    }

    public void Save(AppSettings settings)
    {
        var directory = Path.GetDirectoryName(configPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporary = configPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(
                temporary,
                JsonSerializer.Serialize(settings, AppSettings.JsonOptions));
            File.Move(temporary, configPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private AppSettings RestoreDefaults()
    {
        var defaults = AppSettings.CreateDefault(documentsDirectory);
        Save(defaults);
        return defaults;
    }
}
