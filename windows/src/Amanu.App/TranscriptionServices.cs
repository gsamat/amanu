using System.Diagnostics;
using System.IO;
using System.Net.Http.Headers;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Amanu.Core.Processing;

namespace Amanu.App;

public sealed record SessionAudio(
    string Directory,
    string Title,
    string? Microphone,
    string? System,
    string? Single,
    int MicrophoneOffsetMs,
    int SystemOffsetMs);

public interface ITranscriptionEngine
{
    Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken);
}

public sealed class LocalTranscriptionEngine(
    ModelManager models,
    string model,
    string? language) : ITranscriptionEngine
{
    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var segments = new List<TranscriptSegment>();
        if (audio.Microphone is not null && audio.System is not null)
        {
            segments.AddRange(await TranscribeFileAsync(audio.Microphone, "me", audio.MicrophoneOffsetMs, cancellationToken));
            segments.AddRange(await TranscribeFileAsync(audio.System, "them", audio.SystemOffsetMs, cancellationToken));
        }
        else
        {
            var source = audio.Single ?? audio.Microphone ?? audio.System
                ?? throw new InvalidOperationException("The session has no audio file.");
            segments.AddRange(await TranscribeFileAsync(source, null, 0, cancellationToken));
        }
        return new TranscriptDocument("local", model, DateTimeOffset.UtcNow,
            segments.OrderBy(segment => segment.StartMs).ToArray());
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribeFileAsync(
        string source, string? speaker, int offsetMs, CancellationToken cancellationToken)
    {
        var cli = models.CliPath ?? throw new InvalidOperationException("Install the local transcription runtime first.");
        var modelPath = models.ModelPath(model);
        if (!File.Exists(modelPath)) throw new InvalidOperationException($"Install the {model} local model first.");
        var temp = Path.Combine(Path.GetTempPath(), "Amanu", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var wave = Path.Combine(temp, "input.wav");
            AudioPreprocessor.ConvertToMono16k(source, wave);
            var batch = Path.Combine(temp, "batch.txt");
            await File.WriteAllTextAsync(batch, wave + Environment.NewLine, cancellationToken).ConfigureAwait(false);
            var start = new ProcessStartInfo(cli)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("-m");
            start.ArgumentList.Add(modelPath);
            start.ArgumentList.Add("--batch");
            start.ArgumentList.Add(batch);
            start.ArgumentList.Add("--batch-jsonl");
            start.ArgumentList.Add("--timestamps");
            start.ArgumentList.Add("auto");
            if (!string.IsNullOrWhiteSpace(language))
            {
                start.ArgumentList.Add("--language");
                start.ArgumentList.Add(language);
            }
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not launch local transcription.");
            var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            var output = await outputTask.ConfigureAwait(false);
            var error = await errorTask.ConfigureAwait(false);
            if (process.ExitCode != 0) throw new InvalidOperationException($"Local transcription failed: {error.Trim()}");
            var result = LocalCliResultParser.Parse(output);
            if (result.Segments.Count > 0)
                return result.Segments.Select(item => item with
                {
                    StartMs = item.StartMs + offsetMs,
                    EndMs = item.EndMs + offsetMs,
                    Speaker = speaker ?? item.Speaker,
                }).ToArray();
            return string.IsNullOrWhiteSpace(result.Text)
                ? []
                : [new TranscriptSegment(offsetMs, offsetMs, result.Text, speaker)];
        }
        finally
        {
            if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        }
    }
}

public sealed class AssemblyAiTranscriptionEngine(HttpClient httpClient, string apiKey) : ITranscriptionEngine
{
    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var temporary = Path.Combine(audio.Directory, ".assembly-input.wav");
        var deleteTemporary = false;
        try
        {
            string source;
            if (audio.Microphone is not null && audio.System is not null)
            {
                AudioPreprocessor.CreateAlignedStereo16k(
                    audio.Microphone, audio.System, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, temporary);
                source = temporary;
                deleteTemporary = true;
            }
            else source = audio.Single ?? audio.Microphone ?? audio.System
                ?? throw new InvalidOperationException("The session has no audio file.");

            using var uploadRequest = new HttpRequestMessage(HttpMethod.Post, "https://api.assemblyai.com/v2/upload");
            uploadRequest.Headers.TryAddWithoutValidation("authorization", apiKey);
            uploadRequest.Content = new StreamContent(File.OpenRead(source));
            using var upload = await httpClient.SendAsync(uploadRequest, cancellationToken).ConfigureAwait(false);
            upload.EnsureSuccessStatusCode();
            var uploadJson = await upload.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
            var uploadUrl = uploadJson.GetProperty("upload_url").GetString();

            using var create = new HttpRequestMessage(HttpMethod.Post, "https://api.assemblyai.com/v2/transcript");
            create.Headers.TryAddWithoutValidation("authorization", apiKey);
            create.Content = JsonContent.Create(new
            {
                audio_url = uploadUrl,
                speech_models = new[] { "universal-3-pro", "universal-2" },
                speaker_labels = true,
                multichannel = audio.Microphone is not null && audio.System is not null,
                format_text = true,
            });
            using var created = await httpClient.SendAsync(create, cancellationToken).ConfigureAwait(false);
            created.EnsureSuccessStatusCode();
            var createdJson = await created.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
            var id = createdJson.GetProperty("id").GetString();
            JsonElement result;
            while (true)
            {
                await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken).ConfigureAwait(false);
                using var poll = new HttpRequestMessage(HttpMethod.Get, $"https://api.assemblyai.com/v2/transcript/{id}");
                poll.Headers.TryAddWithoutValidation("authorization", apiKey);
                using var response = await httpClient.SendAsync(poll, cancellationToken).ConfigureAwait(false);
                response.EnsureSuccessStatusCode();
                result = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
                var status = result.GetProperty("status").GetString();
                if (status == "completed") break;
                if (status == "error") throw new InvalidOperationException(result.GetProperty("error").GetString());
            }
            await File.WriteAllTextAsync(Path.Combine(audio.Directory, "assemblyai-response.json"), result.GetRawText(), cancellationToken)
                .ConfigureAwait(false);
            var segments = ParseAssemblySegments(result);
            return new TranscriptDocument("assemblyai", "universal-3-pro", DateTimeOffset.UtcNow, segments);
        }
        finally
        {
            if (deleteTemporary) File.Delete(temporary);
        }
    }

    private static IReadOnlyList<TranscriptSegment> ParseAssemblySegments(JsonElement root)
    {
        if (!root.TryGetProperty("utterances", out var utterances) || utterances.ValueKind != JsonValueKind.Array)
        {
            var text = root.TryGetProperty("text", out var value) ? value.GetString() : null;
            return string.IsNullOrWhiteSpace(text) ? [] : [new TranscriptSegment(0, 0, text)];
        }
        return utterances.EnumerateArray().Select(item =>
        {
            var rawSpeaker = ReadString(item, "speaker") ?? ReadString(item, "channel") ?? "speaker";
            var speaker = rawSpeaker.StartsWith('1') || rawSpeaker.Equals("A", StringComparison.OrdinalIgnoreCase)
                ? "me"
                : rawSpeaker.StartsWith('2') || rawSpeaker.Equals("B", StringComparison.OrdinalIgnoreCase)
                    ? "them"
                    : rawSpeaker;
            return new TranscriptSegment(ReadLong(item, "start"), ReadLong(item, "end"), ReadString(item, "text") ?? "", speaker);
        }).Where(item => !string.IsNullOrWhiteSpace(item.Text)).ToArray();
    }

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static long ReadLong(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.TryGetInt64(out var result) ? result : 0;
}

public sealed class OpenAiTranscriptionEngine(HttpClient httpClient, string apiKey, string model) : ITranscriptionEngine
{
    public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var temp = Path.Combine(Path.GetTempPath(), "Amanu", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        try
        {
            var mixed = Path.Combine(temp, "mixed.wav");
            if (audio.Microphone is not null && audio.System is not null)
            {
                var stereo = Path.Combine(temp, "stereo.wav");
                AudioPreprocessor.CreateAlignedStereo16k(
                    audio.Microphone, audio.System, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, stereo);
                AudioPreprocessor.MixStereoToMono16k(stereo, mixed);
            }
            else AudioPreprocessor.ConvertToMono16k(audio.Single ?? audio.Microphone ?? audio.System
                ?? throw new InvalidOperationException("The session has no audio file."), mixed);

            var all = new List<TranscriptSegment>();
            foreach (var part in AudioPreprocessor.SplitWav(mixed, Path.Combine(temp, "parts")))
                all.AddRange(await TranscribePartAsync(part.Path, part.OffsetSeconds, cancellationToken));
            return new TranscriptDocument("openai", model, DateTimeOffset.UtcNow, all);
        }
        finally
        {
            if (Directory.Exists(temp)) Directory.Delete(temp, recursive: true);
        }
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribePartAsync(
        string path, double offsetSeconds, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(model), "model");
        content.Add(new StringContent("diarized_json"), "response_format");
        content.Add(new StringContent("auto"), "chunking_strategy");
        var file = new StreamContent(File.OpenRead(path));
        file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        content.Add(file, "file", Path.GetFileName(path));
        request.Content = content;
        using var response = await httpClient.SendAsync(request, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var json = await response.Content.ReadFromJsonAsync<JsonElement>(cancellationToken).ConfigureAwait(false);
        if (!json.TryGetProperty("segments", out var segments)) return [];
        return segments.EnumerateArray().Select(item => new TranscriptSegment(
            (long)((ReadDouble(item, "start") + offsetSeconds) * 1000),
            (long)((ReadDouble(item, "end") + offsetSeconds) * 1000),
            item.GetProperty("text").GetString() ?? "",
            item.TryGetProperty("speaker", out var speaker) ? speaker.GetString() : null)).ToArray();
    }

    private static double ReadDouble(JsonElement item, string name) =>
        item.TryGetProperty(name, out var value) && value.TryGetDouble(out var result) ? result : 0;
}
