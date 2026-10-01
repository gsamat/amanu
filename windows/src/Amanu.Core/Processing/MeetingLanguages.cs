namespace Amanu.Core.Processing;

/// <summary>
/// The languages a meeting may be in, and how much of that an engine may be told.
/// </summary>
public static class MeetingLanguages
{
    /// <summary>First in the menu: the languages Amanu is actually used in.</summary>
    public static readonly IReadOnlyList<string> Pinned = ["en", "ru", "de", "fr", "es"];

    /// <summary>Each language's name in itself — Deutsch, not German.</summary>
    public static readonly IReadOnlyDictionary<string, string> Names = new Dictionary<string, string>
    {
        ["en"] = "English", ["ru"] = "Русский", ["de"] = "Deutsch", ["fr"] = "Français", ["es"] = "Español",
        ["be"] = "Беларуская", ["bg"] = "Български", ["cs"] = "Čeština", ["da"] = "Dansk", ["el"] = "Ελληνικά",
        ["et"] = "Eesti", ["fi"] = "Suomi", ["hr"] = "Hrvatski", ["hu"] = "Magyar", ["it"] = "Italiano",
        ["lt"] = "Lietuvių", ["lv"] = "Latviešu", ["mt"] = "Malti", ["nl"] = "Nederlands", ["pl"] = "Polski",
        ["pt"] = "Português", ["ro"] = "Română", ["sk"] = "Slovenčina", ["sl"] = "Slovenščina", ["sv"] = "Svenska",
        ["uk"] = "Українська",
    };

    public static IReadOnlyList<string> Menu =>
        [.. Pinned, .. Names.Keys.Where(code => !Pinned.Contains(code)).OrderBy(code => Names[code], StringComparer.CurrentCulture)];

    /// <summary>
    /// What a meeting "mostly in" a language may be in: that language and English,
    /// which turns up in every meeting's vocabulary. Empty means detect anything.
    /// </summary>
    public static IReadOnlyList<string> Expected(string? primary)
    {
        var code = primary?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(code) || !Names.ContainsKey(code)) return [];
        return code == "en" ? [code] : [code, "en"];
    }

    /// <summary>
    /// The one language an engine may be told outright, or null to let it detect.
    /// A language parameter is a pin, not a hint: "mostly Russian" means Russian
    /// and English, and a pin on either is how the other comes back as fluent
    /// nonsense. So only a single expected language is ever pinned.
    /// </summary>
    public static string? Pin(IReadOnlyList<string> expected) => expected.Count == 1 ? expected[0] : null;
}
