using System.Net.Http.Headers;
using System.Net.Http;
using System.IO;
using System.Net.Http.Json;
using System.Text.Json;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;

namespace Amanu.App;

public sealed class LanguageModelService(HttpClient httpClient, SecretStore secrets, AppSettings settings)
{
    public async Task<(string Text, string Backend, string Model)> GenerateAsync(
        string prompt,
        string backend,
        string? modelOverride,
        CancellationToken cancellationToken)
    {
        var selected = SelectBackend(backend);
        return selected switch
        {
            "anthropic" => (await AnthropicAsync(prompt, modelOverride ?? settings.Summary.AnthropicModel, cancellationToken),
                "anthropic", modelOverride ?? settings.Summary.AnthropicModel),
            "openai" => (await OpenAiAsync(prompt, modelOverride ?? settings.Summary.OpenAiModel, cancellationToken),
                "openai", modelOverride ?? settings.Summary.OpenAiModel),
            "ollama" => (await OllamaAsync(prompt, modelOverride ?? settings.Summary.OllamaModel, cancellationToken),
                "ollama", modelOverride ?? settings.Summary.OllamaModel),
            _ => throw new InvalidOperationException("Configure an OpenAI or Anthropic key, or run Ollama locally."),
        };
    }

    private string SelectBackend(string backend)
    {
        if (!backend.Equals("auto", StringComparison.OrdinalIgnoreCase)) return backend.ToLowerInvariant();
        if (!string.IsNullOrWhiteSpace(secrets.Get("anthropic"))) return "anthropic";
        if (!string.IsNullOrWhiteSpace(secrets.Get("openai"))) return "openai";
        return "ollama";
    }

    private async Task<string> AnthropicAsync(string prompt, string model, CancellationToken cancellationToken)
    {
        var key = secrets.Get("anthropic") ?? throw new InvalidOperationException("Anthropic API key is missing.");
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        request.Headers.Add("x-api-key", key);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Content = JsonContent.Create(new
        {
            model,
            max_tokens = 4_096,
            messages = new[] { new { role = "user", content = prompt } },
        });
        using var response = await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
        return json.GetProperty("content").EnumerateArray()
            .Where(item => item.GetProperty("type").GetString() == "text")
            .Select(item => item.GetProperty("text").GetString())
            .FirstOrDefault() ?? throw new InvalidDataException("Anthropic returned no text.");
    }

    private async Task<string> OpenAiAsync(string prompt, string model, CancellationToken cancellationToken)
    {
        var key = secrets.Get("openai") ?? throw new InvalidOperationException("OpenAI API key is missing.");
        var baseUrl = settings.Summary.OpenAiBaseUrl.TrimEnd('/');
        using var request = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/responses");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Content = JsonContent.Create(new { model, input = prompt });
        using var response = await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
        if (json.TryGetProperty("output_text", out var direct)) return direct.GetString() ?? "";
        if (json.TryGetProperty("output", out var output))
            foreach (var item in output.EnumerateArray())
                if (item.TryGetProperty("content", out var content))
                    foreach (var part in content.EnumerateArray())
                        if (part.TryGetProperty("text", out var text)) return text.GetString() ?? "";
        throw new InvalidDataException("OpenAI returned no text.");
    }

    private async Task<string> OllamaAsync(string prompt, string model, CancellationToken cancellationToken)
    {
        using var response = await httpClient.PostAsJsonAsync(
            settings.Summary.OllamaUrl.TrimEnd('/') + "/api/generate",
            new { model, prompt, stream = false }, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
        return json.GetProperty("response").GetString() ?? throw new InvalidDataException("Ollama returned no text.");
    }
}

public sealed class SpeakerNamingService(LanguageModelService languageModel, AppSettings settings)
{
    public async Task<IReadOnlyDictionary<string, string>> ResolveAsync(
        string sessionDirectory,
        TranscriptDocument transcript,
        CancellationToken cancellationToken)
    {
        var path = Path.Combine(sessionDirectory, "speakers.json");
        var existing = await ReadExistingAsync(path, cancellationToken).ConfigureAwait(false);
        var names = new Dictionary<string, string>(existing, StringComparer.OrdinalIgnoreCase);
        if (transcript.Segments.Any(segment => segment.Speaker == "me"))
            names.TryAdd("me", string.IsNullOrWhiteSpace(settings.UserName) ? Environment.UserName : settings.UserName);
        var unresolved = transcript.Segments.Select(segment => segment.Speaker)
            .Where(label => !string.IsNullOrWhiteSpace(label) && !names.ContainsKey(label!)).Distinct().ToArray();
        if (unresolved.Length > 0)
        {
            var plain = string.Join("\n", transcript.Segments.Select(segment => $"{segment.Speaker}: {segment.Text}"));
            var prompt = $$"""
                Identify real speaker names only when the transcript itself contains strong evidence.
                Return only JSON: {"proposals":[{"speaker":"label","name":"Full name","confidence":"high|medium|low","quote":"an exact supporting quote of at least two words"}]}.
                Unknown labels: {{string.Join(", ", unresolved)}}

                Transcript:
                {{plain}}
                """;
            var generated = await languageModel.GenerateAsync(prompt, settings.SpeakerNames.Backend, settings.SpeakerNames.Model, cancellationToken)
                .ConfigureAwait(false);
            foreach (var proposal in ParseProposals(generated.Text))
                if (!names.ContainsKey(proposal.Speaker) && SpeakerNameValidator.Accept(proposal.Confidence, proposal.Quote, plain))
                    names[proposal.Speaker] = proposal.Name;
        }
        await AtomicFiles.WriteJsonAsync(path, new { source = "automatic", names }, cancellationToken).ConfigureAwait(false);
        return names;
    }

    private static async Task<Dictionary<string, string>> ReadExistingAsync(string path, CancellationToken cancellationToken)
    {
        if (!File.Exists(path)) return new(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false));
            if (!json.RootElement.TryGetProperty("names", out var names)) return new(StringComparer.OrdinalIgnoreCase);
            return names.EnumerateObject().ToDictionary(pair => pair.Name, pair => pair.Value.GetString() ?? pair.Name,
                StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException) { return new(StringComparer.OrdinalIgnoreCase); }
    }

    private static IEnumerable<Proposal> ParseProposals(string text)
    {
        var start = text.IndexOf('{');
        var end = text.LastIndexOf('}');
        if (start < 0 || end <= start) yield break;
        JsonDocument json;
        try { json = JsonDocument.Parse(text[start..(end + 1)]); }
        catch (JsonException) { yield break; }
        using (json)
        {
            if (!json.RootElement.TryGetProperty("proposals", out var proposals)) yield break;
            foreach (var item in proposals.EnumerateArray())
            {
                if (!item.TryGetProperty("speaker", out var speaker) || !item.TryGetProperty("name", out var name) ||
                    !item.TryGetProperty("confidence", out var confidence) || !item.TryGetProperty("quote", out var quote)) continue;
                yield return new Proposal(speaker.GetString() ?? "", name.GetString() ?? "",
                    confidence.GetString() ?? "", quote.GetString() ?? "");
            }
        }
    }

    private sealed record Proposal(string Speaker, string Name, string Confidence, string Quote);
}

public sealed class SummaryService(LanguageModelService languageModel, AppSettings settings)
{
    public async Task GenerateAsync(string sessionDirectory, string transcriptMarkdown, CancellationToken cancellationToken)
    {
        var template = string.IsNullOrWhiteSpace(settings.Summary.Template) ? SummaryTemplate.Default : settings.Summary.Template;
        var chunks = SummaryChunker.Split(transcriptMarkdown);
        var partial = new List<string>();
        foreach (var chunk in chunks)
        {
            var language = string.IsNullOrWhiteSpace(settings.Summary.Language) ? "Use the transcript's language." : $"Write in {settings.Summary.Language}.";
            var prompt = $"{template}\n\n{language}\n\nTranscript:\n{chunk}";
            partial.Add((await languageModel.GenerateAsync(prompt, settings.Summary.Backend, null, cancellationToken).ConfigureAwait(false)).Text);
        }
        var summary = partial.Count == 1
            ? partial[0]
            : (await languageModel.GenerateAsync(
                $"Merge these partial meeting notes into one note using this exact structure. Remove repetition.\n\n{template}\n\n{string.Join("\n\n---\n\n", partial)}",
                settings.Summary.Backend, null, cancellationToken).ConfigureAwait(false)).Text;
        await AtomicFiles.WriteTextAsync(Path.Combine(sessionDirectory, "summary.md"), summary.Trim() + Environment.NewLine, cancellationToken)
            .ConfigureAwait(false);
    }
}

public static class AtomicFiles
{
    public static Task WriteJsonAsync(string path, object value, CancellationToken cancellationToken) =>
        WriteTextAsync(path, JsonSerializer.Serialize(value, new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }), cancellationToken);

    public static async Task WriteTextAsync(string path, string value, CancellationToken cancellationToken)
    {
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await File.WriteAllTextAsync(temporary, value, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
