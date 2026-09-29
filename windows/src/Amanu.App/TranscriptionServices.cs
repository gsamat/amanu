using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Amanu.Core.Processing;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

/// <summary>
/// The audio of one session as the engines see it. A track that is missing or
/// never delivered a sample is null — a silent side, not a failure of the whole
/// session, as long as some other track has audio.
/// </summary>
public sealed record SessionAudio(
    string Directory,
    string Title,
    string? Microphone,
    string? System,
    string? Single,
    int MicrophoneOffsetMs,
    int SystemOffsetMs)
{
    public bool HasAudio => Microphone is not null || System is not null || Single is not null;
    public bool BothSides => Microphone is not null && System is not null;

    /// <summary>The one file there is, with the side it belongs to ("" when it is an import).</summary>
    public (string Path, string Side, int OffsetMs) Only =>
        Single is not null ? (Single, "", 0)
        : Microphone is not null ? (Microphone, SpeakerLabels.Me, MicrophoneOffsetMs)
        : System is not null ? (System, SpeakerLabels.Them, SystemOffsetMs)
        : throw new ProcessingFailure(FailureKind.Recording, T("The session has no audio.", "В записи нет звука."));
}

public interface ITranscriptionEngine
{
    string Name { get; }
    Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken);
}

/// <summary>What was sent to a paid service, kept beside the session so a crash after the upload does not pay twice.</summary>
internal static class ProviderCache
{
    public static string? PathFor(string? directory, string provider, params string[] parts)
    {
        if (directory is null) return null;
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\u001F', parts))))[..16];
        return System.IO.Path.Combine(directory, $".cache-{provider}-{hash}.json");
    }

    /// <summary>Every cache in a session, for a re-transcription to throw away: a corrected language must not return the old text.</summary>
    public static void Clear(string directory)
    {
        if (!System.IO.Directory.Exists(directory)) return;
        foreach (var file in System.IO.Directory.EnumerateFiles(directory, ".cache-*.json")) File.Delete(file);
        File.Delete(System.IO.Path.Combine(directory, ".assemblyai-job.json"));
    }

    public static string KeyDigest(string key) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..16];
}

internal static class Http
{
    public static async Task<HttpResponseMessage> SendAsync(
        HttpClient client, Func<HttpRequestMessage> request, string service, CancellationToken cancellationToken)
    {
        HttpResponseMessage response;
        try
        {
            using var message = request();
            response = await client.SendAsync(message, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException exception)
        {
            throw ProcessingFailure.FromHttp(service, null, exception.Message);
        }
        catch (TaskCanceledException exception) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ProcessingFailure(FailureKind.Transient, T($"{service} timed out", $"{service} не ответил вовремя"), exception);
        }
        if (response.IsSuccessStatusCode) return response;
        var detail = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        response.Dispose();
        throw ProcessingFailure.FromHttp(service, status, detail);
    }
}

/// <summary>transcribe.cpp on this computer, one call per track: mic is "me", the call is "them".</summary>
public sealed class LocalTranscriptionEngine(ModelManager models, string model, string? languagePin) : ITranscriptionEngine
{
    public string Name => model;

    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var segments = new List<TranscriptSegment>();
        if (audio.BothSides)
        {
            segments.AddRange(await TranscribeFileAsync(audio.Microphone!, SpeakerLabels.Me, audio.MicrophoneOffsetMs, cancellationToken));
            segments.AddRange(await TranscribeFileAsync(audio.System!, SpeakerLabels.Them, audio.SystemOffsetMs, cancellationToken));
        }
        else
        {
            var (path, side, offset) = audio.Only;
            segments.AddRange(await TranscribeFileAsync(path, side, offset, cancellationToken));
        }
        return new TranscriptDocument(model, model, DateTimeOffset.UtcNow,
            SpeakerLabels.Assign(segments.OrderBy(segment => segment.StartMs).ToArray()));
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribeFileAsync(
        string source, string side, int offsetMs, CancellationToken cancellationToken)
    {
        var cli = models.CliPath ?? throw new ProcessingFailure(FailureKind.Environmental,
            T("The local transcription runtime is missing from this installation.", "В этой установке нет локального движка расшифровки."));
        var modelPath = models.ModelPath(model);
        if (!File.Exists(modelPath))
            throw new ProcessingFailure(FailureKind.Environmental, T($"{EngineResolver.DisplayName(model)} isn't downloaded.", $"{EngineResolver.DisplayName(model)} не скачана."));
        var temp = Path.Combine(Path.GetTempPath(), "Amanu", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var wave = Path.Combine(temp, "input.wav");
            AudioPreprocessor.ConvertToMono16k(source, wave);
            var batch = Path.Combine(temp, "batch.txt");
            await File.WriteAllTextAsync(batch, wave + Environment.NewLine, cancellationToken).ConfigureAwait(false);
            // The CLI writes UTF-8. Left unsaid, .NET reads a windowless app's pipes
            // in the ANSI code page, and every Cyrillic word comes back as mojibake
            // while English survives — which is how the first real recording found it.
            var start = new ProcessStartInfo(cli)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var argument in new[] { "-m", modelPath, "--batch", batch, "--batch-jsonl", "--timestamps", "auto" })
                start.ArgumentList.Add(argument);
            if (!string.IsNullOrWhiteSpace(languagePin))
            {
                start.ArgumentList.Add("--language");
                start.ArgumentList.Add(languagePin);
            }
            using var process = Process.Start(start) ?? throw new ProcessingFailure(FailureKind.Environmental,
                T("Could not launch local transcription.", "Не удалось запустить локальную расшифровку."));
            using var registration = cancellationToken.Register(() => { try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false);
            var error = await errorTask.ConfigureAwait(false);
            // A negative exit code is Windows ending the process — a missing DLL, a
            // crash, no memory — which says nothing against the recording.
            if (process.ExitCode != 0)
                throw new ProcessingFailure(process.ExitCode < 0 ? FailureKind.Environmental : FailureKind.Recording,
                    T("Local transcription failed: ", "Локальная расшифровка не удалась: ") + $"({process.ExitCode}) " + error.Trim());
            var result = LocalCliResultParser.Parse(output);
            if (result.Segments.Count > 0)
                return result.Segments.Select(item => item with
                {
                    StartMs = item.StartMs + offsetMs,
                    EndMs = item.EndMs + offsetMs,
                    Speaker = SpeakerLabels.Raw(side, item.Speaker ?? ""),
                }).ToArray();
            return string.IsNullOrWhiteSpace(result.Text)
                ? []
                : [new TranscriptSegment(offsetMs, offsetMs, result.Text, SpeakerLabels.Raw(side, ""))];
        }
        finally
        {
            if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        }
    }
}

/// <summary>
/// AssemblyAI over aligned two-channel audio: mic on channel 1, the call on
/// channel 2, each diarized on its own. Detection is narrowed to the expected
/// languages rather than pinned, because a pin on the wrong language returns
/// fluent phonetic garbage instead of failing.
/// </summary>
public sealed class AssemblyAiTranscriptionEngine(
    HttpClient httpClient,
    string apiKey,
    IReadOnlyList<string> expectedLanguages,
    string? speechModel,
    bool cache = true) : ITranscriptionEngine
{
    private const string Service = "AssemblyAI";

    public string Name => "assemblyai";

    private string Model => speechModel ?? "universal";

    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var temporary = Path.Combine(audio.Directory, ".assemblyai-input.wav");
        try
        {
            string source;
            string side;
            if (audio.BothSides)
            {
                AudioPreprocessor.CreateAlignedStereo16k(
                    audio.Microphone!, audio.System!, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, temporary);
                source = temporary;
                side = "*";
            }
            else
            {
                var only = audio.Only;
                AudioPreprocessor.ConvertToMono16k(only.Path, temporary);
                source = temporary;
                side = only.Side;
            }
            var multichannel = side == "*";
            var shift = audio.BothSides ? Math.Min(audio.MicrophoneOffsetMs, audio.SystemOffsetMs) : audio.Only.OffsetMs;
            var cachePath = cache
                ? ProviderCache.PathFor(audio.Directory, "assemblyai", Model, string.Join('+', expectedLanguages),
                    multichannel ? "multichannel" : "mono", side, new FileInfo(source).Length.ToString())
                : null;

            JsonElement result;
            if (cachePath is not null && File.Exists(cachePath))
                result = JsonDocument.Parse(await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false)).RootElement.Clone();
            else
            {
                var id = await ResumableJobAsync(audio.Directory, cachePath)
                         ?? await SubmitAsync(source, multichannel, audio.Directory, cachePath, cancellationToken).ConfigureAwait(false);
                try
                {
                    result = await PollAsync(id, cancellationToken).ConfigureAwait(false);
                }
                catch (ProcessingFailure failure) when (failure.Kind == FailureKind.Recording)
                {
                    // A job that errored or is gone is not resumed: the next attempt submits afresh.
                    File.Delete(Path.Combine(audio.Directory, ".assemblyai-job.json"));
                    throw;
                }
                if (cachePath is not null)
                    await AtomicFiles.WriteTextAsync(cachePath, result.GetRawText(), cancellationToken).ConfigureAwait(false);
                File.Delete(Path.Combine(audio.Directory, ".assemblyai-job.json"));
            }
            var segments = Segments(result, side);
            if (shift != 0)
                segments = segments.Select(segment => segment with { StartMs = segment.StartMs + shift, EndMs = segment.EndMs + shift }).ToArray();
            return new TranscriptDocument("assemblyai", Model, DateTimeOffset.UtcNow, SpeakerLabels.Assign(segments));
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    /// <summary>
    /// A job submitted before a crash, polled rather than uploaded and paid for
    /// again — but only with the key that submitted it and for the same request:
    /// another key cannot read it, and a different request is a different job.
    /// </summary>
    private Task<string?> ResumableJobAsync(string directory, string? cachePath)
    {
        var path = Path.Combine(directory, ".assemblyai-job.json");
        if (cachePath is null || !File.Exists(path)) return Task.FromResult<string?>(null);
        try
        {
            using var job = JsonDocument.Parse(File.ReadAllText(path));
            var root = job.RootElement;
            return Task.FromResult(
                root.GetProperty("key").GetString() == ProviderCache.KeyDigest(apiKey) && root.GetProperty("cache").GetString() == Path.GetFileName(cachePath)
                    ? root.GetProperty("id").GetString()
                    : null);
        }
        catch (Exception exception) when (exception is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return Task.FromResult<string?>(null);
        }
    }

    private async Task<string> SubmitAsync(string source, bool multichannel, string directory, string? cachePath, CancellationToken cancellationToken)
    {
        using var upload = await Http.SendAsync(httpClient, () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Post, "https://api.assemblyai.com/v2/upload");
            request.Headers.TryAddWithoutValidation("authorization", apiKey);
            request.Content = new StreamContent(File.OpenRead(source));
            return request;
        }, Service, cancellationToken).ConfigureAwait(false);
        var uploadUrl = (await upload.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false))
            .GetProperty("upload_url").GetString();

        var body = new Dictionary<string, object?>
        {
            ["audio_url"] = uploadUrl,
            ["speaker_labels"] = true,
            ["punctuate"] = true,
            ["format_text"] = true,
            ["language_detection"] = true,
        };
        if (multichannel) body["multichannel"] = true;
        if (expectedLanguages.Count > 0)
            body["language_detection_options"] = new { expected_languages = expectedLanguages, fallback_language = expectedLanguages[0] };
        if (speechModel is not null) body["speech_model"] = speechModel;

        using var created = await Http.SendAsync(httpClient, () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Post, "https://api.assemblyai.com/v2/transcript");
            request.Headers.TryAddWithoutValidation("authorization", apiKey);
            request.Content = JsonContent.Create(body);
            return request;
        }, Service, cancellationToken).ConfigureAwait(false);
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false)).GetProperty("id").GetString()!;
        if (cachePath is not null)
            await AtomicFiles.WriteJsonAsync(Path.Combine(directory, ".assemblyai-job.json"),
                new { id, key = ProviderCache.KeyDigest(apiKey), cache = Path.GetFileName(cachePath) }, cancellationToken).ConfigureAwait(false);
        return id;
    }

    /// <summary>
    /// A poll is a free GET against a job already paid for, so a failed one is sat
    /// out rather than given up on. A job the service no longer has is dropped, so
    /// the next attempt submits afresh.
    /// </summary>
    private async Task<JsonElement> PollAsync(string id, CancellationToken cancellationToken)
    {
        var failures = 0;
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken).ConfigureAwait(false);
            JsonElement result;
            try
            {
                using var response = await Http.SendAsync(httpClient, () =>
                {
                    var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.assemblyai.com/v2/transcript/{id}");
                    request.Headers.TryAddWithoutValidation("authorization", apiKey);
                    return request;
                }, Service, cancellationToken).ConfigureAwait(false);
                result = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
                failures = 0;
            }
            // Sat out: the network dropping or the service busy. Not a refused key,
            // which no amount of waiting fixes.
            catch (ProcessingFailure failure) when ((failure.Kind == FailureKind.Transient || failure.Unreachable) && ++failures < 60)
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(60, 5 * failures)), cancellationToken).ConfigureAwait(false);
                continue;
            }
            var status = result.GetProperty("status").GetString();
            if (status == "completed") return result;
            if (status == "error")
                throw new ProcessingFailure(FailureKind.Recording, "AssemblyAI: " + result.GetProperty("error").GetString());
        }
    }

    private static IReadOnlyList<TranscriptSegment> Segments(JsonElement root, string side)
    {
        if (!root.TryGetProperty("utterances", out var utterances) || utterances.ValueKind != JsonValueKind.Array)
        {
            var text = ReadString(root, "text");
            return string.IsNullOrWhiteSpace(text) ? [] : [new TranscriptSegment(0, 0, text, SpeakerLabels.Raw(side == "*" ? "" : side, ""))];
        }
        return utterances.EnumerateArray().Select(item =>
        {
            var speaker = ReadString(item, "speaker") ?? "";
            var channel = ReadString(item, "channel") ?? (speaker.Length > 0 && char.IsDigit(speaker[0]) ? speaker[..1] : null);
            var voice = speaker.TrimStart('0', '1', '2', '3', '4', '5', '6', '7', '8', '9');
            var itemSide = side != "*" ? side : channel == "1" ? SpeakerLabels.Me : channel == "2" ? SpeakerLabels.Them : "";
            return new TranscriptSegment(ReadLong(item, "start"), ReadLong(item, "end"), ReadString(item, "text") ?? "",
                SpeakerLabels.Raw(itemSide, voice));
        }).Where(item => !string.IsNullOrWhiteSpace(item.Text)).ToArray();
    }

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()
        : element.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Number ? value.GetRawText() : null;

    private static long ReadLong(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt64(out var result) ? result : 0;
}

/// <summary>
/// OpenAI's diarizing model over one mixed-down file, cut into ten-minute pieces.
/// Its speakers are mapped back onto me and them by comparing each voice's
/// energy in the two tracks, since the mix itself cannot say who was where.
/// </summary>
public sealed class OpenAiTranscriptionEngine(
    HttpClient httpClient,
    string apiKey,
    string model,
    string? languagePin,
    bool cache = true) : ITranscriptionEngine
{
    private const string Service = "OpenAI";

    public string Name => "openai";

    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var temp = Path.Combine(Path.GetTempPath(), "Amanu", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var mixed = Path.Combine(temp, "mixed.wav");
            string? stereo = null;
            var offset = 0;
            string side = "";
            if (audio.BothSides)
            {
                stereo = Path.Combine(temp, "stereo.wav");
                AudioPreprocessor.CreateAlignedStereo16k(
                    audio.Microphone!, audio.System!, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, stereo);
                AudioPreprocessor.ConvertToMono16k(stereo, mixed);
                offset = Math.Min(audio.MicrophoneOffsetMs, audio.SystemOffsetMs);
            }
            else
            {
                var only = audio.Only;
                AudioPreprocessor.ConvertToMono16k(only.Path, mixed);
                side = only.Side;
                offset = only.OffsetMs;
            }

            var parts = AudioPreprocessor.SplitWav(mixed, Path.Combine(temp, "parts"));
            var all = new List<TranscriptSegment>();
            for (var index = 0; index < parts.Count; index++)
            {
                var part = parts[index];
                var cachePath = cache
                    ? ProviderCache.PathFor(audio.Directory, "openai", model, languagePin ?? "detect", $"{index}/{parts.Count}",
                        new FileInfo(part.Path).Length.ToString())
                    : null;
                string json;
                if (cachePath is not null && File.Exists(cachePath)) json = await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
                else
                {
                    json = await TranscribePartAsync(part.Path, cancellationToken).ConfigureAwait(false);
                    if (cachePath is not null) await AtomicFiles.WriteTextAsync(cachePath, json, cancellationToken).ConfigureAwait(false);
                }
                // Voices are named per request, so "A" in one piece is not "A" in the next.
                all.AddRange(Parse(json, part.OffsetSeconds).Select(segment => segment with { Speaker = $"{index}:{segment.Speaker}" }));
            }

            var sides = stereo is null
                ? all.Select(segment => segment.Speaker!).Distinct().ToDictionary(label => label, _ => side)
                : AudioPreprocessor.SideByEnergy(stereo, all);
            var labelled = all.Select(segment => segment with
            {
                StartMs = segment.StartMs + offset,
                EndMs = segment.EndMs + offset,
                Speaker = SpeakerLabels.Raw(sides.GetValueOrDefault(segment.Speaker!, ""), segment.Speaker),
            }).ToArray();
            return new TranscriptDocument("openai", model, DateTimeOffset.UtcNow, SpeakerLabels.Assign(labelled));
        }
        finally
        {
            if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        }
    }

    private async Task<string> TranscribePartAsync(string path, CancellationToken cancellationToken)
    {
        using var response = await Http.SendAsync(httpClient, () =>
        {
            var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            var content = new MultipartFormDataContent
            {
                { new StringContent(model), "model" },
                { new StringContent("diarized_json"), "response_format" },
                { new StringContent("auto"), "chunking_strategy" },
            };
            if (languagePin is not null) content.Add(new StringContent(languagePin), "language");
            var file = new StreamContent(File.OpenRead(path));
            file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            content.Add(file, "file", Path.GetFileName(path));
            request.Content = content;
            return request;
        }, Service, cancellationToken).ConfigureAwait(false);
        return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
    }

    private static IReadOnlyList<TranscriptSegment> Parse(string json, double offsetSeconds)
    {
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("segments", out var segments)) return [];
        return segments.EnumerateArray().Select(item => new TranscriptSegment(
            (long)((ReadDouble(item, "start") + offsetSeconds) * 1000),
            (long)((ReadDouble(item, "end") + offsetSeconds) * 1000),
            item.TryGetProperty("text", out var text) ? text.GetString() ?? "" : "",
            item.TryGetProperty("speaker", out var speaker) ? speaker.GetString() ?? "" : ""))
            .Where(segment => !string.IsNullOrWhiteSpace(segment.Text)).ToArray();
    }

    private static double ReadDouble(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.TryGetDouble(out var result) ? result : 0;
}

/// <summary>ElevenLabs Scribe, each track on its own: the track says the side, diarization the voice.</summary>
public sealed class ElevenLabsTranscriptionEngine(HttpClient httpClient, string apiKey, bool cache = true) : ITranscriptionEngine
{
    private const string Service = "ElevenLabs";
    private const string Model = "scribe_v2";

    public string Name => "elevenlabs";

    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var tracks = audio.BothSides
            ? new[] { (audio.Microphone!, SpeakerLabels.Me, audio.MicrophoneOffsetMs), (audio.System!, SpeakerLabels.Them, audio.SystemOffsetMs) }
            : [audio.Only];
        var all = new List<TranscriptSegment>();
        foreach (var (path, side, offset) in tracks)
        {
            var temp = Path.Combine(audio.Directory, $".elevenlabs-{side}.wav");
            try
            {
                AudioPreprocessor.ConvertToMono16k(path, temp);
                var cachePath = cache ? ProviderCache.PathFor(audio.Directory, "elevenlabs", Model, side, new FileInfo(temp).Length.ToString()) : null;
                string json;
                if (cachePath is not null && File.Exists(cachePath)) json = await File.ReadAllTextAsync(cachePath, cancellationToken).ConfigureAwait(false);
                else
                {
                    using var response = await Http.SendAsync(httpClient, () =>
                    {
                        var request = new HttpRequestMessage(HttpMethod.Post, "https://api.elevenlabs.io/v1/speech-to-text");
                        request.Headers.TryAddWithoutValidation("xi-api-key", apiKey);
                        var content = new MultipartFormDataContent
                        {
                            { new StringContent(Model), "model_id" },
                            { new StringContent("word"), "timestamps_granularity" },
                            { new StringContent("false"), "tag_audio_events" },
                            { new StringContent("true"), "diarize" },
                        };
                        var file = new StreamContent(File.OpenRead(temp));
                        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
                        content.Add(file, "file", "audio.wav");
                        request.Content = content;
                        return request;
                    }, Service, cancellationToken).ConfigureAwait(false);
                    json = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                    if (cachePath is not null) await AtomicFiles.WriteTextAsync(cachePath, json, cancellationToken).ConfigureAwait(false);
                }
                all.AddRange(Turns(json, side, offset));
            }
            finally
            {
                File.Delete(temp);
            }
        }
        return new TranscriptDocument("elevenlabs", Model, DateTimeOffset.UtcNow,
            SpeakerLabels.Assign(all.OrderBy(segment => segment.StartMs).ToArray()));
    }

    /// <summary>Words joined into turns: one voice, no gap longer than a second and a half.</summary>
    private static IEnumerable<TranscriptSegment> Turns(string json, string side, int offsetMs)
    {
        using var document = JsonDocument.Parse(json);
        var turns = new List<(double Start, double End, StringBuilder Text, string Voice)>();
        string? lastVoice = null;
        if (document.RootElement.TryGetProperty("words", out var words))
        {
            foreach (var word in words.EnumerateArray())
            {
                var type = word.TryGetProperty("type", out var t) ? t.GetString() : "word";
                var text = word.TryGetProperty("text", out var w) ? w.GetString() ?? "" : "";
                var voice = word.TryGetProperty("speaker_id", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString()! : lastVoice ?? "";
                if (type == "spacing")
                {
                    if (turns.Count > 0 && turns[^1].Voice == voice) turns[^1].Text.Append(text);
                    continue;
                }
                if (type != "word") continue;
                var start = word.GetProperty("start").GetDouble();
                var end = word.GetProperty("end").GetDouble();
                lastVoice = voice;
                if (turns.Count > 0 && turns[^1].Voice == voice && start - turns[^1].End <= 1.5)
                {
                    turns[^1].Text.Append(text);
                    turns[^1] = turns[^1] with { End = Math.Max(turns[^1].End, end) };
                }
                else turns.Add((start, end, new StringBuilder(text), voice));
            }
        }
        foreach (var turn in turns)
        {
            var text = turn.Text.ToString().Trim();
            if (text.Length > 0)
                yield return new TranscriptSegment((long)(turn.Start * 1000) + offsetMs, (long)(turn.End * 1000) + offsetMs, text,
                    SpeakerLabels.Raw(side, turn.Voice));
        }
    }
}
