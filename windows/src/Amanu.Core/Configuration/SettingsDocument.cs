using System.Text.Json;
using System.Text.Json.Nodes;

namespace Amanu.Core.Configuration;

/// <summary>Settings as a JSON tree, for the edits that go by path rather than by property.</summary>
public static class SettingsDocument
{
    public static JsonObject ToNode(AppSettings settings) =>
        JsonSerializer.SerializeToNode(settings, AppSettings.JsonOptions)!.AsObject();

    public static AppSettings FromNode(JsonNode node) =>
        node.Deserialize<AppSettings>(AppSettings.JsonOptions)
        ?? throw new JsonException("The settings are empty.");

    public static JsonNode? Get(JsonNode root, string path)
    {
        JsonNode? current = root;
        foreach (var key in path.Split('.'))
        {
            if (current is not JsonObject item || !item.TryGetPropertyValue(key, out current)) return null;
        }
        return current;
    }

    /// <summary>
    /// A copy of <paramref name="settings"/> with one value replaced. A null
    /// value puts the default back, which is how a field is cleared.
    /// </summary>
    public static AppSettings With(AppSettings settings, string path, JsonNode? value, string homeDirectory)
    {
        var root = ToNode(settings);
        var keys = path.Split('.');
        var parent = root;
        foreach (var key in keys[..^1])
        {
            if (parent[key] is not JsonObject child)
            {
                child = new JsonObject();
                parent[key] = child;
            }
            parent = child;
        }
        var replacement = value ?? SettingsSchema.DefaultFor(path, homeDirectory);
        parent[keys[^1]] = replacement?.DeepClone();
        return FromNode(root);
    }

    /// <summary>
    /// Only what differs from the defaults. The file then reads as a list of the
    /// person's decisions, and a default that improves in a later version
    /// reaches them instead of being frozen into their file the first time a
    /// window saved it — the rule the macOS app follows.
    /// </summary>
    public static JsonObject Changes(AppSettings settings, AppSettings defaults)
    {
        var result = new JsonObject();
        Collect(ToNode(settings), ToNode(defaults), result);
        return result;
    }

    private static void Collect(JsonObject current, JsonObject defaults, JsonObject into)
    {
        foreach (var (key, value) in current)
        {
            defaults.TryGetPropertyValue(key, out var fallback);
            if (value is JsonObject nested && fallback is JsonObject nestedDefaults)
            {
                var child = new JsonObject();
                Collect(nested, nestedDefaults, child);
                if (child.Count > 0) into[key] = child;
            }
            else if (!JsonNode.DeepEquals(value, fallback))
            {
                into[key] = value?.DeepClone();
            }
        }
    }
}
