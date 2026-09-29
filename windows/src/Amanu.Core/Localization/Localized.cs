using System.Globalization;

namespace Amanu.Core.Localization;

/// <summary>
/// The language Amanu's own windows are in. Not the language meetings are held
/// in, and not the one summaries are written in: those are settings of their own.
/// </summary>
/// <remarks>
/// It is settled once at startup, from <c>interface_language</c> in the config
/// and otherwise from the Windows display language, the same way the macOS app
/// decides it: Russian when Windows is in Russian, English everywhere else. A
/// change takes effect at the next launch, because every window reads its words
/// once, when it is built.
/// </remarks>
public enum InterfaceLanguage
{
    English,
    Russian,
}

public static class Localized
{
    public const string Automatic = "auto";
    public static readonly IReadOnlyList<string> ConfiguredValues = [Automatic, "en", "ru"];

    private static InterfaceLanguage process = InterfaceLanguage.English;
    private static readonly AsyncLocal<InterfaceLanguage?> scoped = new();

    /// <summary>English until the application settles it at startup.</summary>
    public static InterfaceLanguage Current
    {
        get => scoped.Value ?? process;
        set => process = value;
    }

    /// <summary>
    /// The language for one flow of work and everything it awaits, without
    /// touching the process's — how a test asks for Russian while tests beside it
    /// run in parallel and expect English.
    /// </summary>
    public static IDisposable Use(InterfaceLanguage language)
    {
        var previous = scoped.Value;
        scoped.Value = language;
        return new Restore(() => scoped.Value = previous);
    }

    private sealed class Restore(Action restore) : IDisposable
    {
        public void Dispose() => restore();
    }

    public static string Code => Current == InterfaceLanguage.Russian ? "ru" : "en";

    public static CultureInfo Culture => CultureInfo.GetCultureInfo(Code == "ru" ? "ru-RU" : "en-US");

    /// <summary>One thing Amanu says, in both languages it can say it in.</summary>
    /// <remarks>
    /// The pair sits where the words are used rather than in a resource table, as
    /// on macOS: the sentence a person sees stays visible in the code that puts it
    /// on screen. Names of things (AssemblyAI, Ollama, parakeet) are not translated.
    /// </remarks>
    public static string T(string english, string russian) =>
        Current == InterfaceLanguage.Russian ? russian : english;

    /// <summary>The whole decision, as a function of its two inputs.</summary>
    /// <remarks>
    /// Only the first display language decides: a Polish Windows whose owner
    /// also reads Russian stays in English.
    /// </remarks>
    public static InterfaceLanguage Choose(string? configured, string systemLanguage)
    {
        if (!string.IsNullOrWhiteSpace(configured) && configured != Automatic)
        {
            if (configured.Equals("ru", StringComparison.OrdinalIgnoreCase)) return InterfaceLanguage.Russian;
            if (configured.Equals("en", StringComparison.OrdinalIgnoreCase)) return InterfaceLanguage.English;
        }
        var code = systemLanguage.Split('-', '_')[0];
        return code.Equals("ru", StringComparison.OrdinalIgnoreCase) ? InterfaceLanguage.Russian : InterfaceLanguage.English;
    }
}
