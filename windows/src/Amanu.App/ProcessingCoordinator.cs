using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Channels;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;

namespace Amanu.App;

public sealed record ProcessingStatus(string? SessionDirectory, string Stage, string Message, bool IsBusy);

public sealed class ProcessingCoordinator : IAsyncDisposable
{
    private readonly AppSettings settings;
    private readonly SecretStore secrets;
    private readonly ModelManager models;
    private readonly HttpClient httpClient;
    private readonly AnalyticsService analytics;
    private readonly Channel<string> queue = Channel.CreateUnbounded<string>();
    private readonly CancellationTokenSource lifetime = new();
    private readonly HashSet<string> queued = new(StringComparer.OrdinalIgnoreCase);
    private readonly object queueLock = new();
    private Task? worker;

    public ProcessingCoordinator(AppSettings settings, SecretStore secrets, ModelManager models, HttpClient httpClient, AnalyticsService analytics)
    {
        this.settings = settings;
        this.secrets = secrets;
        this.models = models;
        this.httpClient = httpClient;
        this.analytics = analytics;
    }

    public event EventHandler<ProcessingStatus>? StatusChanged;
    public event EventHandler? SessionsChanged;

    public void Start()
    {
        worker ??= Task.Run(() => WorkerAsync(lifetime.Token));
        if (!Directory.Exists(settings.RecordingsDirectory)) return;
        foreach (var directory in Directory.EnumerateDirectories(settings.RecordingsDirectory))
        {
            var hasMeta = File.Exists(Path.Combine(directory, "meta.json"));
            var hasTranscript = File.Exists(Path.Combine(directory, "transcript.json"));
            var needsTranscript = !hasTranscript &&
                                  !File.Exists(Path.Combine(directory, "transcribe.failed")) &&
                                  !File.Exists(Path.Combine(directory, "transcribe.off"));
            var needsSpeakers = hasTranscript && settings.SpeakerNames.Enabled &&
                                !File.Exists(Path.Combine(directory, "speakers.json"));
            var needsSummary = hasTranscript && settings.Summary.Enabled &&
                               !File.Exists(Path.Combine(directory, "summary.md"));
            if (hasMeta && (needsTranscript || needsSpeakers || needsSummary))
                Enqueue(directory);
        }
    }

    public void Enqueue(string sessionDirectory)
    {
        lock (queueLock)
        {
            if (!queued.Add(sessionDirectory)) return;
        }
        queue.Writer.TryWrite(sessionDirectory);
        StatusChanged?.Invoke(this, new ProcessingStatus(sessionDirectory, "queued", "Queued for processing", true));
    }

    public async Task EnsureLocalModelAsync(string model, CancellationToken cancellationToken = default) =>
        await models.EnsureReadyAsync(model, cancellationToken).ConfigureAwait(false);

    public async Task<string> ImportAsync(string source, CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.Now;
        var safeTitle = Path.GetFileNameWithoutExtension(source);
        var directory = Path.Combine(settings.RecordingsDirectory, $"{started:yyyy.MM.dd-HHmm} {safeTitle}");
        for (var suffix = 2; Directory.Exists(directory); suffix++)
            directory = Path.Combine(settings.RecordingsDirectory, $"{started:yyyy.MM.dd-HHmm} {safeTitle}-{suffix}");
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, "source" + Path.GetExtension(source).ToLowerInvariant());
        await using (var input = File.OpenRead(source))
        await using (var output = File.Create(destination))
            await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
        await AtomicFiles.WriteJsonAsync(Path.Combine(directory, "meta.json"), new
        {
            started,
            ended = started,
            duration_seconds = AudioPreprocessor.DurationSeconds(destination),
            title = safeTitle,
            trigger = "import",
            stop_reason = "imported",
            platform = "windows",
            files = new { source = Path.GetFileName(destination) },
        }, cancellationToken).ConfigureAwait(false);
        Enqueue(directory);
        SessionsChanged?.Invoke(this, EventArgs.Empty);
        return directory;
    }

    public void Retry(string directory, bool retranscribe)
    {
        foreach (var marker in new[] { "transcribe.failed", "transcribe.deferred", "speakers.failed", "summary.failed", "summary.deferred", "processing.json" })
            File.Delete(Path.Combine(directory, marker));
        if (retranscribe)
        {
            foreach (var artifact in new[] { "transcript.json", "transcript.md", "speakers.json", "summary.md" })
                File.Delete(Path.Combine(directory, artifact));
        }
        else
        {
            File.Delete(Path.Combine(directory, "speakers.json"));
            File.Delete(Path.Combine(directory, "summary.md"));
        }
        Enqueue(directory);
    }

    public async Task SetSpeakerNameAsync(string directory, string label, string name, CancellationToken cancellationToken = default)
    {
        var transcriptPath = Path.Combine(directory, "transcript.json");
        var transcript = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcriptPath, cancellationToken).ConfigureAwait(false))
                         ?? throw new InvalidDataException("Transcript is invalid.");
        var speakersPath = Path.Combine(directory, "speakers.json");
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (File.Exists(speakersPath))
        {
            using var current = JsonDocument.Parse(await File.ReadAllTextAsync(speakersPath, cancellationToken).ConfigureAwait(false));
            if (current.RootElement.TryGetProperty("names", out var existing))
                foreach (var pair in existing.EnumerateObject()) names[pair.Name] = pair.Value.GetString() ?? pair.Name;
        }
        names[label] = name.Trim();
        await AtomicFiles.WriteJsonAsync(speakersPath, new { source = "manual", names }, cancellationToken).ConfigureAwait(false);
        await TranscriptWriter.WriteAsync(directory, await ReadTitleAsync(directory, cancellationToken), transcript, names, cancellationToken)
            .ConfigureAwait(false);
        SessionsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task WorkerAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var directory in queue.Reader.ReadAllAsync(cancellationToken))
            {
                try { await ProcessAsync(directory, cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
                finally
                {
                    lock (queueLock) queued.Remove(directory);
                    SessionsChanged?.Invoke(this, EventArgs.Empty);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    private async Task ProcessAsync(string directory, CancellationToken cancellationToken)
    {
        var attempts = await ReadAttemptsAsync(directory, cancellationToken).ConfigureAwait(false) + 1;
        await AtomicFiles.WriteJsonAsync(Path.Combine(directory, "processing.json"), new { attempts, stage = "transcribing", updated_at = DateTimeOffset.UtcNow }, cancellationToken)
            .ConfigureAwait(false);
        Publish(directory, "transcribing", "Transcribing recording…", true);
        try
        {
            TranscriptDocument transcript;
            var transcriptPath = Path.Combine(directory, "transcript.json");
            if (File.Exists(transcriptPath))
            {
                transcript = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcriptPath, cancellationToken).ConfigureAwait(false))
                             ?? throw new InvalidDataException("Transcript is invalid.");
            }
            else
            {
                if (!settings.Transcription.Enabled)
                {
                    await AtomicFiles.WriteTextAsync(Path.Combine(directory, "transcribe.off"), "disabled", cancellationToken).ConfigureAwait(false);
                    File.Delete(Path.Combine(directory, "processing.json"));
                    await RunHookAsync(directory, cancellationToken).ConfigureAwait(false);
                    Publish(directory, "complete", "Recording saved (transcription is off)", false);
                    return;
                }
                var audio = await LoadAudioAsync(directory, cancellationToken).ConfigureAwait(false);
                transcript = await TranscribeWithFallbackAsync(audio, cancellationToken).ConfigureAwait(false);
                if (settings.Transcription.EchoFilter || settings.Transcription.OfflineEchoCancellation)
                    transcript = transcript with { Segments = TranscriptEchoFilter.Filter(transcript.Segments) };
                if (transcript.Segments.Count == 0 || transcript.Segments.All(segment => string.IsNullOrWhiteSpace(segment.Text)))
                    throw new NoSpeechException("No speech was detected in this recording.");
                await TranscriptWriter.WriteAsync(directory, audio.Title, transcript, cancellationToken: cancellationToken).ConfigureAwait(false);
                File.Delete(Path.Combine(directory, "transcribe.deferred"));
                _ = analytics.RecordAsync("transcript_finished", new Dictionary<string, object?>
                {
                    ["engine"] = transcript.Engine,
                    ["model"] = KnownModel(transcript.Engine, transcript.Model),
                });
            }

            IReadOnlyDictionary<string, string> names = new Dictionary<string, string>();
            if (settings.SpeakerNames.Enabled)
            {
                Publish(directory, "speakers", "Resolving speaker names…", true);
                var language = new LanguageModelService(httpClient, secrets, settings);
                try
                {
                    names = await new SpeakerNamingService(language, settings).ResolveAsync(directory, transcript, cancellationToken).ConfigureAwait(false);
                    await TranscriptWriter.WriteAsync(directory, await ReadTitleAsync(directory, cancellationToken), transcript, names, cancellationToken)
                        .ConfigureAwait(false);
                    File.Delete(Path.Combine(directory, "speakers.deferred"));
                    File.Delete(Path.Combine(directory, "speakers.failed"));
                    _ = analytics.RecordAsync("speaker_names_finished", new Dictionary<string, object?>
                    {
                        ["backend"] = settings.SpeakerNames.Backend,
                        ["model"] = "custom",
                    });
                }
                catch (Exception exception) when (exception is HttpRequestException or InvalidOperationException)
                {
                    await AtomicFiles.WriteTextAsync(Path.Combine(directory, "speakers.deferred"), exception.Message, cancellationToken).ConfigureAwait(false);
                    _ = analytics.RecordAsync("speaker_names_failed", new Dictionary<string, object?>
                    {
                        ["backend"] = settings.SpeakerNames.Backend, ["model"] = "custom",
                        ["reason"] = Reason(exception), ["outcome"] = "deferred",
                    });
                }
            }
            else await AtomicFiles.WriteTextAsync(Path.Combine(directory, "speakers.off"), "disabled", cancellationToken).ConfigureAwait(false);
            if (settings.Summary.Enabled)
            {
                Publish(directory, "summary", "Writing summary…", true);
                var markdown = await File.ReadAllTextAsync(Path.Combine(directory, "transcript.md"), cancellationToken).ConfigureAwait(false);
                try
                {
                    await new SummaryService(new LanguageModelService(httpClient, secrets, settings), settings)
                        .GenerateAsync(directory, markdown, cancellationToken).ConfigureAwait(false);
                    File.Delete(Path.Combine(directory, "summary.deferred"));
                    File.Delete(Path.Combine(directory, "summary.failed"));
                    _ = analytics.RecordAsync("summary_finished", new Dictionary<string, object?>
                    {
                        ["backend"] = settings.Summary.Backend, ["model"] = KnownSummaryModel(),
                    });
                }
                catch (Exception exception) when (exception is HttpRequestException or InvalidOperationException)
                {
                    await AtomicFiles.WriteTextAsync(Path.Combine(directory, "summary.deferred"), exception.Message, cancellationToken).ConfigureAwait(false);
                    _ = analytics.RecordAsync("summary_failed", new Dictionary<string, object?>
                    {
                        ["backend"] = settings.Summary.Backend, ["reason"] = Reason(exception), ["outcome"] = "deferred",
                    });
                }
            }
            else await AtomicFiles.WriteTextAsync(Path.Combine(directory, "summary.off"), "disabled", cancellationToken).ConfigureAwait(false);
            if (settings.KeepAudio)
            {
                var sourceAudio = await LoadAudioAsync(directory, cancellationToken).ConfigureAwait(false);
                if (sourceAudio.Microphone is not null || sourceAudio.System is not null || sourceAudio.Single is not null)
                    await CompactAudioAsync(sourceAudio, cancellationToken).ConfigureAwait(false);
            }
            else DeleteSourceAudio(directory);
            File.Delete(Path.Combine(directory, "processing.json"));
            await RunHookAsync(directory, cancellationToken).ConfigureAwait(false);
            Publish(directory, "complete", $"Finished {Path.GetFileName(directory)}", false);
        }
        catch (NoSpeechException exception)
        {
            await AtomicFiles.WriteTextAsync(Path.Combine(directory, "transcribe.failed"), exception.Message, cancellationToken).ConfigureAwait(false);
            Publish(directory, "failed", exception.Message, false);
        }
        catch (Exception exception)
        {
            await File.AppendAllTextAsync(Path.Combine(directory, "transcribe.log"), $"{DateTimeOffset.UtcNow:O} {exception}\n", cancellationToken).ConfigureAwait(false);
            var marker = attempts >= 3 ? "transcribe.failed" : "transcribe.deferred";
            await AtomicFiles.WriteTextAsync(Path.Combine(directory, marker), exception.Message, cancellationToken).ConfigureAwait(false);
            _ = analytics.RecordAsync("transcript_failed", new Dictionary<string, object?>
            {
                ["engine"] = settings.Transcription.Engine,
                ["model"] = "unknown",
                ["reason"] = Reason(exception),
                ["outcome"] = attempts >= 3 ? "gave_up" : "deferred",
            });
            if (attempts < 3 && !exception.Message.Contains("Configure a cloud", StringComparison.OrdinalIgnoreCase))
                _ = ScheduleRetryAsync(directory, cancellationToken);
            Publish(directory, attempts >= 3 ? "failed" : "deferred", exception.Message, false);
        }
    }

    private async Task<TranscriptDocument> TranscribeWithFallbackAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var cloudKey = settings.Transcription.Cloud.Equals("openai", StringComparison.OrdinalIgnoreCase)
            ? secrets.Get("openai")
            : secrets.Get("assemblyai");
        var localReady = ModelCatalog.Models.ContainsKey(settings.Transcription.LocalEngine) && models.IsReady(settings.Transcription.LocalEngine);
        var selection = EngineSelector.Select(settings.Transcription.Engine, !string.IsNullOrWhiteSpace(cloudKey), localReady);
        if (selection == "unavailable") throw new InvalidOperationException("Configure a cloud API key or install a local transcription model in Setup.");
        if (selection is "cloud" or "cloud-or-local")
        {
            try { return await CreateCloud(cloudKey!).TranscribeAsync(audio, cancellationToken).ConfigureAwait(false); }
            catch (HttpRequestException exception) when (selection == "cloud-or-local")
            {
                _ = analytics.RecordAsync("transcript_fallback", new Dictionary<string, object?>
                {
                    ["from_engine"] = settings.Transcription.Cloud,
                    ["to_engine"] = settings.Transcription.LocalEngine,
                    ["reason"] = Reason(exception),
                });
            }
        }
        return await new LocalTranscriptionEngine(models, settings.Transcription.LocalEngine, settings.Transcription.Language)
            .TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
    }

    private ITranscriptionEngine CreateCloud(string key) => settings.Transcription.Cloud.ToLowerInvariant() switch
    {
        "openai" => new OpenAiTranscriptionEngine(httpClient, key, settings.Transcription.OpenAiModel),
        _ => new AssemblyAiTranscriptionEngine(httpClient, key),
    };

    private static async Task<SessionAudio> LoadAudioAsync(string directory, CancellationToken cancellationToken)
    {
        using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), cancellationToken).ConfigureAwait(false));
        var root = meta.RootElement;
        var title = root.TryGetProperty("title", out var titleValue) && !string.IsNullOrWhiteSpace(titleValue.GetString())
            ? titleValue.GetString()!
            : Path.GetFileName(directory);
        string? mic = Existing(directory, "mic.wav");
        string? system = Existing(directory, "system.wav");
        var single = Directory.EnumerateFiles(directory).FirstOrDefault(path =>
            new[] { "source", "audio" }.Contains(Path.GetFileNameWithoutExtension(path), StringComparer.OrdinalIgnoreCase) && IsAudio(path));
        var micOffset = 0;
        var systemOffset = 0;
        if (root.TryGetProperty("start_offset_ms", out var offsets))
        {
            if (offsets.TryGetProperty("mic", out var value)) value.TryGetInt32(out micOffset);
            if (offsets.TryGetProperty("system", out value)) value.TryGetInt32(out systemOffset);
        }
        return new SessionAudio(directory, title, mic, system, single, micOffset, systemOffset);
    }

    private static string? Existing(string directory, string name)
    {
        var path = Path.Combine(directory, name);
        return File.Exists(path) ? path : null;
    }

    private static bool IsAudio(string path) => new[] { ".wav", ".m4a", ".mp3", ".flac", ".ogg", ".mp4", ".aac" }
        .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    private static async Task<string> ReadTitleAsync(string directory, CancellationToken cancellationToken)
    {
        using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), cancellationToken).ConfigureAwait(false));
        return meta.RootElement.TryGetProperty("title", out var value) && !string.IsNullOrWhiteSpace(value.GetString())
            ? value.GetString()!
            : Path.GetFileName(directory);
    }

    private static async Task<int> ReadAttemptsAsync(string directory, CancellationToken cancellationToken)
    {
        var path = Path.Combine(directory, "processing.json");
        if (!File.Exists(path)) return 0;
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false));
            return json.RootElement.TryGetProperty("attempts", out var attempts) ? attempts.GetInt32() : 0;
        }
        catch (JsonException) { return 0; }
    }

    private static async Task CompactAudioAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        if (File.Exists(Path.Combine(audio.Directory, "audio.m4a"))) return;
        var temp = Path.Combine(audio.Directory, ".archive.wav");
        try
        {
            if (audio.Microphone is not null && audio.System is not null)
                AudioPreprocessor.CreateAlignedStereo16k(audio.Microphone, audio.System, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, temp);
            else AudioPreprocessor.ConvertToMono16k(audio.Single ?? audio.Microphone ?? audio.System!, temp);
            await Task.Run(() => AudioPreprocessor.EncodeAac(temp, Path.Combine(audio.Directory, "audio.m4a")), cancellationToken).ConfigureAwait(false);
            DeleteSourceAudio(audio.Directory);
        }
        finally { File.Delete(temp); }
    }

    private static void DeleteSourceAudio(string directory)
    {
        foreach (var path in Directory.EnumerateFiles(directory).Where(IsAudio))
            if (!Path.GetFileName(path).Equals("audio.m4a", StringComparison.OrdinalIgnoreCase)) File.Delete(path);
    }

    private async Task RunHookAsync(string directory, CancellationToken cancellationToken)
    {
        if (settings.OnStop is not { } hook || string.IsNullOrWhiteSpace(hook.Executable)) return;
        var info = new ProcessStartInfo(hook.Executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in hook.Arguments) info.ArgumentList.Add(argument.Replace("{session}", directory, StringComparison.Ordinal));
        using var process = Process.Start(info);
        if (process is not null) await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
    }

    private void Publish(string directory, string stage, string message, bool busy) =>
        StatusChanged?.Invoke(this, new ProcessingStatus(directory, stage, message, busy));

    private string KnownSummaryModel() => settings.Summary.Backend.ToLowerInvariant() switch
    {
        "openai" when settings.Summary.OpenAiModel == "gpt-5" => "gpt-5",
        "anthropic" when settings.Summary.AnthropicModel == "claude-opus-5" => "claude-opus-5",
        "ollama" when settings.Summary.OllamaModel == "qwen3:8b" => "qwen3:8b",
        "auto" => "default",
        "ollama" => "custom-local",
        _ => "custom",
    };

    private static string KnownModel(string engine, string model) => (engine.ToLowerInvariant(), model) switch
    {
        ("assemblyai", "universal-3-pro") => "universal-3-pro",
        ("openai", "gpt-4o-transcribe-diarize") => "gpt-4o-transcribe-diarize",
        ("local", "parakeet") => "parakeet-v3",
        ("local", "gigaam") => "gigaam-v3",
        ("local", "whisper") => "whisper-large-v3-turbo",
        _ => "custom",
    };

    private static string Reason(Exception exception) => exception switch
    {
        TaskCanceledException => "timed_out",
        HttpRequestException => "no_network",
        InvalidOperationException when exception.Message.Contains("key", StringComparison.OrdinalIgnoreCase) => "no_key",
        InvalidOperationException when exception.Message.Contains("model", StringComparison.OrdinalIgnoreCase) => "no_model",
        _ => "unknown",
    };

    private async Task ScheduleRetryAsync(string directory, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(20), cancellationToken).ConfigureAwait(false);
            Enqueue(directory);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        queue.Writer.TryComplete();
        if (worker is not null)
            try { await worker.ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
    }

    private sealed class NoSpeechException(string message) : Exception(message);
}
