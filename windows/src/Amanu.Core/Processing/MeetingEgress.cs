using Amanu.Core.Configuration;

namespace Amanu.Core.Processing;

public enum EgressPurpose
{
    Summary,
    SpeakerNames,
}

/// <summary>Where one pass may go: a backend preference and the Anthropic model somebody chose.</summary>
public sealed record EgressRoute(string Preference, string? AnthropicModel);

/// <summary>
/// Where the words of a meeting may be sent, decided in one place for every pass
/// that hands them to a language model.
/// </summary>
/// <remarks>
/// The summary goes where <c>summary.backend</c> says, and nowhere when summaries
/// are off or the backend is <c>none</c>. Naming follows the summary unless
/// <c>speaker_names.backend</c> names a backend of its own; with summaries off and
/// no backend of its own, naming asks no model at all. On macOS naming used to
/// default to <c>auto</c> whatever the summary said, so a person who picked
/// Ollama so that nothing left the computer still had every transcript read by a
/// cloud model. Anything new that wants to show a model a transcript asks here.
/// </remarks>
public static class MeetingEgress
{
    public static EgressRoute? Route(EgressPurpose purpose, AppSettings settings)
    {
        var summary = settings.Summary;
        var summaryRoute = summary.Enabled && summary.Backend != "none"
            ? new EgressRoute(summary.Backend, summary.Model)
            : null;
        if (purpose == EgressPurpose.Summary) return summaryRoute;

        var names = settings.SpeakerNames;
        if (!names.Enabled) return null;
        if (names.Backend != "summary")
        {
            return names.Backend == "none" ? null : new EgressRoute(names.Backend, names.Model ?? summary.Model);
        }
        return summaryRoute is null ? null : summaryRoute with { AnthropicModel = names.Model ?? summaryRoute.AnthropicModel };
    }
}

/// <summary>
/// Which language-model backends a preference allows, in the order <c>auto</c>
/// walks them: a subscription already paid for (the claude and codex CLIs) beats
/// a metered key, and Ollama is the floor that needs neither network nor account.
/// </summary>
public static class LanguageModelChain
{
    public static readonly IReadOnlyList<string> Order = ["claude-cli", "anthropic-api", "codex-cli", "openai-api", "ollama"];

    /// <summary>
    /// An explicit name returns just that backend, so a deliberate choice is never
    /// second-guessed; a name nobody recognises allows nothing, rather than
    /// meaning <c>auto</c> and sending a meeting to every cloud model before the
    /// one local backend the person misspelt.
    /// </summary>
    public static IReadOnlyList<string> Allowed(string preference, Func<string, bool> present) =>
        preference == "auto"
            ? Order.Where(present).ToArray()
            : Order.Contains(preference) && present(preference) ? [preference] : [];
}

/// <summary>Which key goes to which server. A key is only ever sent to the service it belongs to.</summary>
public static class KeyRouting
{
    /// <summary>
    /// The key for the summary's OpenAI-compatible Base URL. OpenAI's own key goes
    /// to api.openai.com and, as a last resort, to a server on this computer; a
    /// compatible server elsewhere (OpenRouter, Groq) has a key of its own, so the
    /// OpenAI key cannot leak to it and its key cannot leak to OpenAI.
    /// </summary>
    public static string? SummaryOpenAiKey(string baseUrl, string? openAiKey, string? compatibleKey)
    {
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) return null;
        if (IsOpenAi(uri)) return openAiKey;
        if (!string.IsNullOrWhiteSpace(compatibleKey)) return compatibleKey;
        return IsLocal(uri) ? openAiKey : null;
    }

    public static bool IsOpenAi(Uri uri) =>
        uri.Scheme == Uri.UriSchemeHttps && uri.Host.Equals("api.openai.com", StringComparison.OrdinalIgnoreCase);

    public static bool IsLocal(Uri uri) =>
        uri.IsLoopback || uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Whether a server may be sent a meeting: https anywhere, plain http only on
    /// this computer, where nothing crosses a network to be read on the way.
    /// </summary>
    public static bool AcceptableServer(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && IsLocal(uri)));
}
