using System.Diagnostics;
using System.Collections.Concurrent;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Channels;
using Amanu.Core.Analytics;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

public sealed record ProcessingStatus(string? SessionDirectory, string Stage, string Message, bool IsBusy);

/// <summary>What one session's processing has cost so far, kept in its processing.json.</summary>
public sealed record ProcessingLedger(
    int TranscribeAttempts = 0,
    int NamesAttempts = 0,
    int SummaryAttempts = 0,
    bool HookRan = false,
    bool NamesAsked = false,
    string? LastError = null);

/// <summary>
/// Turns recordings into transcripts, names and summaries, one session at a time.
/// </summary>
/// <remarks>
/// What a failure costs depends on whose fault it was. A missing key, a model not
/// downloaded or no network is this computer's, and waits for the computer to
/// change without using up an attempt; only a failure of the recording itself
/// counts towards the three a transcription gets. Names and summaries give up
/// after five tries that reached a model, so a transcript is not re-sent to
/// every backend at every launch for ever. The on_stop command runs once, after
/// names and summary are done or definitively skipped.
/// </remarks>
public sealed class ProcessingCoordinator : IAsyncDisposable
{
    public const int TranscribeAttemptLimit = 3;
    public const int LanguageModelAttemptLimit = 5;

    private readonly Func<AppSettings> settings;
    private readonly Func<bool> configReadable;
    private readonly SecretStore secrets;
    private readonly ModelManager models;
    private readonly HttpClient httpClient;
    private readonly AnalyticsService analytics;
    private readonly LanguageModels languageModels;
    private readonly Func<string, AppSettings, ITranscriptionEngine>? localEngineFactory;
    private readonly Channel<string> queue = Channel.CreateUnbounded<string>();
    private readonly CancellationTokenSource lifetime = new();
    private readonly HashSet<string> queued = new(StringComparer.OrdinalIgnoreCase);
    private readonly Lock queueLock = new();
    private readonly HashSet<string> again = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> preparing = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, ProcessingStatus> statuses = new(StringComparer.OrdinalIgnoreCase);
    private string? current;
    private Task? worker;

    public ProcessingCoordinator(
        Func<AppSettings> settings,
        Func<bool> configReadable,
        SecretStore secrets,
        ModelManager models,
        HttpClient httpClient,
        AnalyticsService analytics,
        Func<string, AppSettings, ITranscriptionEngine>? localEngineFactory = null)
    {
        this.settings = settings;
        this.configReadable = configReadable;
        this.secrets = secrets;
        this.models = models;
        this.httpClient = httpClient;
        this.analytics = analytics;
        this.localEngineFactory = localEngineFactory;
        languageModels = new LanguageModels(httpClient, secrets, settings);
    }

    public event EventHandler<ProcessingStatus>? StatusChanged;
    public event EventHandler? SessionsChanged;

    public LanguageModels LanguageModels => languageModels;

    public ProcessingStatus? StatusFor(string directory) => statuses.GetValueOrDefault(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar));

    public bool IsBusy
    {
        get { lock (queueLock) return queued.Count > 0; }
    }

    public void Start()
    {
        worker ??= Task.Run(() => WorkerAsync(lifetime.Token));
        Rescan();
    }

    /// <summary>
    /// Queues every session that has work left. Called at launch, when settings
    /// change — a new key, a model downloaded — when the network comes back, and
    /// on a slow clock, which is what lets an environmental failure recover.
    /// </summary>
    public void Rescan()
    {
        var root = settings().RecordingsDirectory;
        try
        {
            if (!Directory.Exists(root)) return;
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                try
                {
                    if (NeedsWork(directory)) Enqueue(directory);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // A recordings folder on a share that just went away; the next rescan tries again.
        }
    }

    private bool NeedsWork(string directory)
    {
        if (Path.GetFileName(directory).StartsWith('.')) return false;
        if (!File.Exists(Path.Combine(directory, "meta.json")) || File.Exists(Path.Combine(directory, ".recording.json"))) return false;
        if (Has(directory, "transcribe.failed")) return false;
        if (Has(directory, "transcribe.off")) return !ReadLedger(directory).HookRan;
        if (!Has(directory, "transcript.json") || Has(directory, TranscriptVersions.RequestFile)) return true;
        var current = settings();
        // A session finished while naming or summaries were off stays that way:
        // switching them on is not a request to send every old meeting to a model.
        // Finish on the session is.
        var namesPending = current.SpeakerNames.Enabled && !Has(directory, "speakers.json") && !Has(directory, "speakers.failed") && !Has(directory, "speakers.off");
        var summaryPending = current.Summary.Enabled && (!Has(directory, "summary.md") || Has(directory, "summary.stale"))
                             && !Has(directory, "summary.failed") && !Has(directory, "summary.off");
        return namesPending || summaryPending || !ReadLedger(directory).HookRan;
    }

    public void Enqueue(string sessionDirectory)
    {
        var directory = Path.GetFullPath(sessionDirectory).TrimEnd(Path.DirectorySeparatorChar);
        lock (queueLock)
        {
            if (preparing.Contains(directory)) return;
            if (!queued.Add(directory))
            {
                // Asked for while it is being worked on: go round once more after,
                // so a change made mid-pass is not lost to the pass that missed it.
                if (string.Equals(current, directory, StringComparison.OrdinalIgnoreCase)) again.Add(directory);
                return;
            }
        }
        Publish(directory, "queued", T("Queued for processing", "В очереди на обработку"), true);
        queue.Writer.TryWrite(directory);
    }

    public Task EnsureLocalModelAsync(string model, CancellationToken cancellationToken = default) =>
        models.EnsureReadyAsync(model, cancellationToken);

    public async Task<string> ImportAsync(string source, CancellationToken cancellationToken = default)
    {
        var root = settings().RecordingsDirectory;
        var started = DateTimeOffset.Now;
        var title = Path.GetFileNameWithoutExtension(source);
        var baseName = $"{started:yyyy.MM.dd-HHmm} {title}";
        var directory = Path.Combine(root, baseName);
        for (var suffix = 2; Directory.Exists(directory); suffix++) directory = Path.Combine(root, $"{baseName}-{suffix}");
        // Copied under a hidden name and renamed once whole, so a rescan never
        // picks up half a file.
        var staging = Path.Combine(root, "." + Path.GetFileName(directory));
        Directory.CreateDirectory(staging);
        var destination = Path.Combine(staging, "source" + Path.GetExtension(source).ToLowerInvariant());
        await using (var input = File.OpenRead(source))
        await using (var output = File.Create(destination))
            await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
        var duration = AudioPreprocessor.DurationSeconds(destination);
        await AtomicFiles.WriteJsonAsync(Path.Combine(staging, "meta.json"), new
        {
            started,
            ended = started.AddSeconds(duration),
            duration_seconds = duration,
            title,
            trigger = "import",
            stop_reason = "imported",
            platform = "windows",
            files = new { source = Path.GetFileName(destination) },
        }, cancellationToken).ConfigureAwait(false);
        Directory.Move(staging, directory);
        Enqueue(directory);
        SessionsChanged?.Invoke(this, EventArgs.Empty);
        return directory;
    }

    /// <summary>
    /// "Finish": clears what gave up or is waiting and tries again, keeping the
    /// transcript and every name somebody typed.
    /// </summary>
    public void Finish(string directory)
    {
        foreach (var marker in new[] { "transcribe.failed", "transcribe.deferred", "speakers.failed", "speakers.deferred", "speakers.off",
                     "summary.failed", "summary.deferred", "summary.off" })
            File.Delete(Path.Combine(directory, marker));
        WriteLedger(directory, ReadLedger(directory) with { TranscribeAttempts = 0, NamesAttempts = 0, SummaryAttempts = 0, LastError = null });
        Enqueue(directory);
    }

    /// <summary>
    /// Transcribes a session again, optionally with a particular engine, which is
    /// remembered by the session so a queue draining in the background never
    /// substitutes its own. Provider caches go, or a corrected language would
    /// return the old text. The existing transcript and names remain available
    /// until the replacement succeeds; completed versions are archived separately.
    /// </summary>
    public async Task RetranscribeAsync(string directory, string? engine, CancellationToken cancellationToken = default)
    {
        directory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar);
        lock (queueLock)
        {
            if (queued.Contains(directory) || !preparing.Add(directory))
                throw new InvalidOperationException(T(
                    "This recording is being processed right now; try again when it finishes.",
                    "Эта запись сейчас обрабатывается — попробуйте, когда закончится."));
        }
        try
        {
            var audio = await LoadAudioAsync(directory, cancellationToken).ConfigureAwait(false);
            if (!audio.HasAudio)
                throw new InvalidOperationException(T(
                    "This session's audio was not kept, so there is nothing to transcribe again.",
                    "Звук этой записи не сохранён, расшифровывать заново нечего."));
            ProviderCache.Clear(directory);
            foreach (var file in new[] { "transcribe.failed", "transcribe.deferred", "transcribe.off",
                         "speakers.failed", "speakers.deferred", "summary.failed", "summary.deferred" })
                File.Delete(Path.Combine(directory, file));
            engine ??= settings().Transcription.Engine;
            var choice = Path.Combine(directory, "transcribe.engine");
            await AtomicFiles.WriteTextAsync(choice, engine, cancellationToken).ConfigureAwait(false);
            // on_stop has had its run for this session; a new transcript does not earn another.
            WriteLedger(directory, new ProcessingLedger(HookRan: ReadLedger(directory).HookRan));
            await AtomicFiles.WriteTextAsync(Path.Combine(directory, TranscriptVersions.RequestFile), engine, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (queueLock) preparing.Remove(directory);
        }
        Enqueue(directory);
    }

    public async Task SetSpeakerNameAsync(string directory, string label, string name, CancellationToken cancellationToken = default, string? title = null)
    {
        var transcript = await ReadTranscriptAsync(directory, cancellationToken).ConfigureAwait(false);
        var file = await SpeakerFile.ReadAsync(directory, cancellationToken).ConfigureAwait(false);
        var names = new Dictionary<string, string>(file.Names);
        var sources = new Dictionary<string, string>(file.Sources);
        if (string.IsNullOrWhiteSpace(name))
        {
            names.Remove(label);
            sources.Remove(label);
        }
        else
        {
            names[label] = name.Trim();
            sources[label] = "manual";
        }
        await SpeakerFile.WriteAsync(directory, names, sources, cancellationToken).ConfigureAwait(false);
        await TranscriptWriter.WriteAsync(directory, title ?? await ReadTitleAsync(directory, cancellationToken), transcript, names, cancellationToken)
            .ConfigureAwait(false);
        SessionsChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task WorkerAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var directory in queue.Reader.ReadAllAsync(cancellationToken))
            {
                lock (queueLock) current = directory;
                try
                {
                    await ProcessAsync(directory, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    return;
                }
                catch (Exception exception)
                {
                    // Nothing one session does may stop the queue for the others:
                    // it is written down, and the session waits for the next pass.
                    try
                    {
                        await File.AppendAllTextAsync(Path.Combine(directory, "transcribe.log"),
                            $"{DateTimeOffset.UtcNow:O} {exception}{Environment.NewLine}", CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (Exception logging) when (logging is IOException or UnauthorizedAccessException) { }
                    Publish(directory, "deferred", exception.Message, false);
                    ScheduleRetry(directory, TimeSpan.FromMinutes(10));
                }
                finally
                {
                    bool repeat;
                    lock (queueLock)
                    {
                        queued.Remove(directory);
                        current = null;
                        repeat = again.Remove(directory);
                    }
                    SessionsChanged?.Invoke(this, EventArgs.Empty);
                    if (repeat) Enqueue(directory);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task ProcessAsync(string directory, CancellationToken cancellationToken)
    {
        if (!Directory.Exists(directory) || !File.Exists(Path.Combine(directory, "meta.json"))) return;
        if (!configReadable())
        {
            Publish(directory, "deferred", T("Waiting for config.json to be fixed", "Жду, пока исправят config.json"), false);
            return;
        }

        var current = settings();
        var title = await ReadTitleAsync(directory, cancellationToken).ConfigureAwait(false);
        var ledger = ReadLedger(directory);

        if (!Has(directory, "transcript.json") || Has(directory, TranscriptVersions.RequestFile))
        {
            if (Has(directory, "transcribe.failed")) return;
            if (!current.Transcription.Enabled && !Has(directory, TranscriptVersions.RequestFile))
            {
                await AtomicFiles.WriteTextAsync(Path.Combine(directory, "transcribe.off"), "disabled", cancellationToken).ConfigureAwait(false);
                await RunHookOnceAsync(directory, cancellationToken).ConfigureAwait(false);
                Publish(directory, "complete", T("Recording saved (transcription is off)", "Запись сохранена (расшифровка выключена)"), false);
                return;
            }
            var transcribed = await TranscribeAsync(directory, title, ledger, cancellationToken).ConfigureAwait(false);
            if (!transcribed) return;
            ledger = ReadLedger(directory);
        }

        var transcript = await ReadTranscriptAsync(directory, cancellationToken).ConfigureAwait(false);
        var namesSettled = await NameSpeakersAsync(directory, title, transcript, cancellationToken).ConfigureAwait(false);
        var summarySettled = await SummarizeAsync(directory, cancellationToken).ConfigureAwait(false);
        if (!namesSettled || !summarySettled) return;

        await RunHookOnceAsync(directory, cancellationToken).ConfigureAwait(false);
        Publish(directory, "complete", T($"Finished {title}", $"Готово: {title}"), false);
    }

    /// <returns>Whether there is now a transcript.</returns>
    private async Task<bool> TranscribeAsync(string directory, string title, ProcessingLedger ledger, CancellationToken cancellationToken)
    {
        var current = settings();
        Publish(directory, "transcribing", T("Transcribing…", "Расшифровываю…"), true);
        var audio = await LoadAudioAsync(directory, cancellationToken).ConfigureAwait(false);
        if (!audio.HasAudio)
        {
            await GiveUpAsync(directory, T("No track in this recording has any audio.", "Ни на одной дорожке записи нет звука."), cancellationToken).ConfigureAwait(false);
            return false;
        }

        var engine = ReadText(directory, "transcribe.engine") ?? current.Transcription.Engine;
        var plan = EngineResolver.Plan(engine, current.Transcription.Cloud, current.Transcription.LocalEngine,
            provider => !string.IsNullOrWhiteSpace(secrets.Get(provider)), models.IsReady);
        if (!plan.Usable)
        {
            await DeferAsync(directory, "transcribe.deferred", plan.Missing!, cancellationToken).ConfigureAwait(false);
            return false;
        }

        try
        {
            var transcript = await RunPlanAsync(plan, audio, current, cancellationToken).ConfigureAwait(false);
            if (current.TranscriptEchoFilter && audio.BothSides)
                transcript = transcript with { Segments = TranscriptEchoFilter.Filter(transcript.Segments) };
            if (transcript.Segments.All(segment => string.IsNullOrWhiteSpace(segment.Text)))
            {
                await GiveUpAsync(directory, T("No speech was heard in this recording.", "В записи не слышно речи."), cancellationToken).ConfigureAwait(false);
                return false;
            }
            var speakers = await SpeakerFile.ReadAsync(directory, cancellationToken).ConfigureAwait(false);
            var replacing = Has(directory, TranscriptVersions.RequestFile);
            var names = replacing
                ? speakers.Names.Where(pair => speakers.Sources.GetValueOrDefault(pair.Key) == "manual").ToDictionary()
                : speakers.Names;
            await TranscriptVersions.ArchiveCurrentAsync(directory, cancellationToken).ConfigureAwait(false);
            if (replacing && Has(directory, "summary.md"))
                await AtomicFiles.WriteTextAsync(Path.Combine(directory, "summary.stale"), "retranscribed", cancellationToken).ConfigureAwait(false);
            await TranscriptWriter.WriteAsync(directory, title, transcript, names, cancellationToken).ConfigureAwait(false);
            if (replacing)
            {
                if (names.Count == 0) File.Delete(Path.Combine(directory, "speakers.json"));
                else await SpeakerFile.WriteAsync(directory, names, names.ToDictionary(pair => pair.Key, _ => "manual"), cancellationToken).ConfigureAwait(false);
                foreach (var marker in new[] { TranscriptVersions.RequestFile, "speakers.off", "summary.off" })
                    File.Delete(Path.Combine(directory, marker));
            }
            File.Delete(Path.Combine(directory, "transcribe.deferred"));
            SessionsChanged?.Invoke(this, EventArgs.Empty);
            WriteLedger(directory, ReadLedger(directory) with { LastError = null });
            _ = analytics.RecordAsync("transcript_finished", new Dictionary<string, object?>
            {
                ["engine"] = transcript.Engine,
                ["model"] = KnownModel(transcript.Engine, transcript.Model),
            });
            try
            {
                await SettleAudioAsync(audio, current.KeepAudio, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // The transcript is safe; the raw tracks stay rather than be lost to a failed archive.
                await File.AppendAllTextAsync(Path.Combine(directory, "transcribe.log"),
                    $"{DateTimeOffset.UtcNow:O} archive: {exception.Message}{Environment.NewLine}", cancellationToken).ConfigureAwait(false);
            }
            return true;
        }
        catch (ProcessingFailure failure)
        {
            await File.AppendAllTextAsync(Path.Combine(directory, "transcribe.log"),
                $"{DateTimeOffset.UtcNow:O} {failure.Kind}: {failure.Message}{Environment.NewLine}", cancellationToken).ConfigureAwait(false);
            if (failure.Kind != FailureKind.Recording)
            {
                await DeferAsync(directory, "transcribe.deferred", failure.Message, cancellationToken).ConfigureAwait(false);
                _ = analytics.RecordAsync("transcript_failed", new Dictionary<string, object?>
                {
                    ["engine"] = engine, ["reason"] = Reason(failure), ["outcome"] = "deferred",
                });
                if (failure.Kind == FailureKind.Transient) ScheduleRetry(directory, TimeSpan.FromMinutes(2));
                return false;
            }
            var attempts = ledger.TranscribeAttempts + 1;
            WriteLedger(directory, ReadLedger(directory) with { TranscribeAttempts = attempts, LastError = failure.Message });
            _ = analytics.RecordAsync("transcript_failed", new Dictionary<string, object?>
            {
                ["engine"] = engine, ["reason"] = Reason(failure), ["outcome"] = attempts >= TranscribeAttemptLimit ? "gave_up" : "deferred",
            });
            if (attempts >= TranscribeAttemptLimit)
            {
                await GiveUpAsync(directory, failure.Message, cancellationToken).ConfigureAwait(false);
                return false;
            }
            await DeferAsync(directory, "transcribe.deferred", failure.Message, cancellationToken).ConfigureAwait(false);
            ScheduleRetry(directory, TimeSpan.FromSeconds(30));
            return false;
        }
    }

    /// <summary>
    /// The cloud first when the plan has one, and this computer's model only when
    /// the cloud could not be reached or was busy — for this session alone.
    /// </summary>
    private async Task<TranscriptDocument> RunPlanAsync(EnginePlan plan, SessionAudio audio, AppSettings current, CancellationToken cancellationToken)
    {
        if (plan.Cloud is { } cloud)
        {
            try
            {
                return await CreateCloud(cloud, current, cache: true).TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
            }
            catch (ProcessingFailure failure) when (plan.Local is not null && failure.Kind != FailureKind.Recording)
            {
                _ = analytics.RecordAsync("transcript_fallback", new Dictionary<string, object?>
                {
                    ["from_engine"] = cloud, ["to_engine"] = plan.Local, ["reason"] = Reason(failure),
                });
                await File.AppendAllTextAsync(Path.Combine(audio.Directory, "transcribe.log"),
                    $"{DateTimeOffset.UtcNow:O} {cloud} → {plan.Local}: {failure.Message}{Environment.NewLine}", cancellationToken).ConfigureAwait(false);
            }
        }
        return await CreateLocal(plan.Local!, current).TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
    }

    public ITranscriptionEngine CreateCloud(string provider, AppSettings current, bool cache)
    {
        var key = secrets.Get(provider) ?? throw new ProcessingFailure(FailureKind.Environmental,
            T($"{EngineResolver.DisplayName(provider)} needs a key.", $"Для {EngineResolver.DisplayName(provider)} нужен ключ."));
        var expected = MeetingLanguages.Expected(current.Transcription.Language);
        return provider switch
        {
            "openai" => new OpenAiTranscriptionEngine(httpClient, key, current.Transcription.OpenAi.Model, MeetingLanguages.Pin(expected), cache),
            "elevenlabs" => new ElevenLabsTranscriptionEngine(httpClient, key, cache),
            _ => new AssemblyAiTranscriptionEngine(httpClient, key, expected, current.Transcription.AssemblyAi.SpeechModel, cache),
        };
    }

    public ITranscriptionEngine CreateLocal(string model, AppSettings current) =>
        localEngineFactory?.Invoke(model, current)
        ?? new LocalTranscriptionEngine(models, model, MeetingLanguages.Pin(MeetingLanguages.Expected(current.Transcription.Language)));

    /// <returns>Whether naming is done, off, or given up on — anything but waiting.</returns>
    private async Task<bool> NameSpeakersAsync(string directory, string title, TranscriptDocument transcript, CancellationToken cancellationToken)
    {
        var current = settings();
        if (!current.SpeakerNames.Enabled)
        {
            await AtomicFiles.WriteTextAsync(Path.Combine(directory, "speakers.off"), "disabled", cancellationToken).ConfigureAwait(false);
            return true;
        }
        if (Has(directory, "speakers.failed") || Has(directory, "speakers.off")) return true;
        if (Has(directory, "speakers.json") && !Has(directory, "speakers.deferred"))
        {
            // Asked once and answered: labels the model could not name stay
            // unnamed rather than send the transcript again at every pass.
            if (ReadLedger(directory).NamesAsked) return true;
            var labels = transcript.Segments.Select(segment => segment.Speaker).OfType<string>().Distinct();
            var known = (await SpeakerFile.ReadAsync(directory, cancellationToken).ConfigureAwait(false)).Names;
            if (labels.All(known.ContainsKey) || MeetingEgress.Route(EgressPurpose.SpeakerNames, current) is null) return true;
        }
        Publish(directory, "speakers", T("Working out who spoke…", "Определяю участников…"), true);
        try
        {
            var result = await new SpeakerNamingService(languageModels, settings).ResolveAsync(directory, transcript, cancellationToken).ConfigureAwait(false);
            await TranscriptWriter.WriteAsync(directory, title, transcript, result.Names, cancellationToken).ConfigureAwait(false);
            File.Delete(Path.Combine(directory, "speakers.deferred"));
            if (result.AskedModel) WriteLedger(directory, ReadLedger(directory) with { NamesAsked = true });
            if (result.AskedModel)
                _ = analytics.RecordAsync("speaker_names_finished", new Dictionary<string, object?> { ["backend"] = current.SpeakerNames.Backend });
            return true;
        }
        catch (ProcessingFailure failure)
        {
            return await LanguageModelFailedAsync(directory, "speakers", failure,
                ledger => ledger.NamesAttempts, (ledger, attempts) => ledger with { NamesAttempts = attempts },
                "speaker_names_failed", current.SpeakerNames.Backend, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <returns>Whether the summary is done, off, or given up on.</returns>
    private async Task<bool> SummarizeAsync(string directory, CancellationToken cancellationToken)
    {
        var current = settings();
        if (MeetingEgress.Route(EgressPurpose.Summary, current) is null)
        {
            if (!Has(directory, "summary.md"))
                await AtomicFiles.WriteTextAsync(Path.Combine(directory, "summary.off"), "disabled", cancellationToken).ConfigureAwait(false);
            return true;
        }
        if (Has(directory, "summary.failed") || Has(directory, "summary.off")) return true;
        if (Has(directory, "summary.md") && !Has(directory, "summary.stale")) return true;
        Publish(directory, "summary", T("Writing the summary…", "Пишу саммари…"), true);
        try
        {
            var markdown = await File.ReadAllTextAsync(Path.Combine(directory, "transcript.md"), cancellationToken).ConfigureAwait(false);
            var answer = await new SummaryService(languageModels, settings).GenerateAsync(directory, markdown, cancellationToken).ConfigureAwait(false);
            File.Delete(Path.Combine(directory, "summary.deferred"));
            _ = analytics.RecordAsync("summary_finished", new Dictionary<string, object?>
            {
                ["backend"] = answer.Backend, ["model"] = answer.Model,
            });
            return true;
        }
        catch (ProcessingFailure failure)
        {
            return await LanguageModelFailedAsync(directory, "summary", failure,
                ledger => ledger.SummaryAttempts, (ledger, attempts) => ledger with { SummaryAttempts = attempts },
                "summary_failed", current.Summary.Backend, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Waits while nothing could be reached; counts every try that reached a model
    /// and gave up after five, so a stale failure is not retried at every launch.
    /// </summary>
    private async Task<bool> LanguageModelFailedAsync(
        string directory, string prefix, ProcessingFailure failure,
        Func<ProcessingLedger, int> attemptsOf, Func<ProcessingLedger, int, ProcessingLedger> withAttempts,
        string analyticsEvent, string backend, CancellationToken cancellationToken)
    {
        var ledger = ReadLedger(directory);
        if (failure.Kind == FailureKind.Environmental)
        {
            await DeferAsync(directory, $"{prefix}.deferred", failure.Message, cancellationToken).ConfigureAwait(false);
            _ = analytics.RecordAsync(analyticsEvent, new Dictionary<string, object?> { ["backend"] = backend, ["reason"] = Reason(failure), ["outcome"] = "deferred" });
            return false;
        }
        var attempts = attemptsOf(ledger) + 1;
        WriteLedger(directory, withAttempts(ledger, attempts) with { LastError = failure.Message });
        var gaveUp = attempts >= LanguageModelAttemptLimit;
        _ = analytics.RecordAsync(analyticsEvent, new Dictionary<string, object?>
        {
            ["backend"] = backend, ["reason"] = Reason(failure), ["outcome"] = gaveUp ? "gave_up" : "deferred",
        });
        if (gaveUp)
        {
            File.Delete(Path.Combine(directory, $"{prefix}.deferred"));
            await AtomicFiles.WriteTextAsync(Path.Combine(directory, $"{prefix}.failed"), failure.Message, cancellationToken).ConfigureAwait(false);
            Publish(directory, "failed", failure.Message, false);
            return true;
        }
        await DeferAsync(directory, $"{prefix}.deferred", failure.Message, cancellationToken).ConfigureAwait(false);
        ScheduleRetry(directory, TimeSpan.FromMinutes(failure.Kind == FailureKind.Transient ? 5 : 1));
        return false;
    }

    private async Task DeferAsync(string directory, string marker, string message, CancellationToken cancellationToken)
    {
        await AtomicFiles.WriteTextAsync(Path.Combine(directory, marker), message, cancellationToken).ConfigureAwait(false);
        WriteLedger(directory, ReadLedger(directory) with { LastError = message });
        Publish(directory, "deferred", message, false);
    }

    /// <summary>
    /// The transcription is over for good. The audio is kept whatever keep_audio
    /// says — a recording that never got a transcript is all there is of that
    /// meeting — but compressed, so a failed session does not hold gigabytes.
    /// </summary>
    private async Task GiveUpAsync(string directory, string message, CancellationToken cancellationToken)
    {
        await AtomicFiles.WriteTextAsync(Path.Combine(directory, "transcribe.failed"), message, cancellationToken).ConfigureAwait(false);
        File.Delete(Path.Combine(directory, "transcribe.deferred"));
        WriteLedger(directory, ReadLedger(directory) with { LastError = message });
        var audio = await LoadAudioAsync(directory, cancellationToken).ConfigureAwait(false);
        if (audio.HasAudio)
        {
            try { await SettleAudioAsync(audio, keep: true, cancellationToken).ConfigureAwait(false); }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // The raw tracks stay; a failed compression costs space, not the meeting.
            }
        }
        Publish(directory, "failed", message, false);
    }

    private void ScheduleRetry(string directory, TimeSpan delay) => _ = Task.Run(async () =>
    {
        try
        {
            await Task.Delay(delay, lifetime.Token).ConfigureAwait(false);
            Enqueue(directory);
        }
        catch (OperationCanceledException) { }
    });

    public static async Task<SessionAudio> LoadAudioAsync(string directory, CancellationToken cancellationToken)
    {
        using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), cancellationToken).ConfigureAwait(false));
        var root = meta.RootElement;
        var title = root.TryGetProperty("title", out var titleValue) && titleValue.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(titleValue.GetString())
            ? titleValue.GetString()!
            : Path.GetFileName(directory);
        var mic = Path.Combine(directory, "mic.wav");
        var system = Path.Combine(directory, "system.wav");
        var single = Directory.EnumerateFiles(directory).FirstOrDefault(path =>
            Path.GetFileNameWithoutExtension(path).Equals("source", StringComparison.OrdinalIgnoreCase) && IsMedia(path));
        var archive = Path.Combine(directory, "audio.m4a");
        if (!AudioPreprocessor.HasSamples(mic) && !AudioPreprocessor.HasSamples(system) && single is null && File.Exists(archive))
        {
            // Kept audio is one stereo file, mic left and the call right, already
            // aligned: split back into its two sides, it transcribes like a fresh
            // recording. The halves are hidden and go when the audio is settled.
            mic = Path.Combine(directory, ".archive-mic.wav");
            system = Path.Combine(directory, ".archive-system.wav");
            if (!File.Exists(mic) || !File.Exists(system)) AudioPreprocessor.SplitStereo(archive, mic, system);
            return new SessionAudio(directory, title, AudioPreprocessor.HasSamples(mic) ? mic : null,
                AudioPreprocessor.HasSamples(system) ? system : null, null, 0, 0);
        }
        var micOffset = 0;
        var systemOffset = 0;
        if (root.TryGetProperty("start_offset_ms", out var offsets))
        {
            if (offsets.TryGetProperty("mic", out var value)) value.TryGetInt32(out micOffset);
            if (offsets.TryGetProperty("system", out value)) value.TryGetInt32(out systemOffset);
        }
        return new SessionAudio(directory, title,
            AudioPreprocessor.HasSamples(mic) ? mic : null,
            AudioPreprocessor.HasSamples(system) ? system : null,
            single, micOffset, systemOffset);
    }

    private static bool IsMedia(string path) => new[] { ".wav", ".m4a", ".mp3", ".flac", ".ogg", ".mp4", ".aac", ".mov", ".mkv", ".webm", ".wma" }
        .Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// After a transcript: one stereo M4A — mic left, the call right — when the
    /// audio is kept, and the raw tracks gone either way.
    /// </summary>
    private static async Task SettleAudioAsync(SessionAudio audio, bool keep, CancellationToken cancellationToken)
    {
        var archive = Path.Combine(audio.Directory, "audio.m4a");
        if (keep && !File.Exists(archive) && (audio.Microphone is not null || audio.System is not null))
        {
            var temp = Path.Combine(audio.Directory, ".archive.wav");
            var partial = Path.Combine(audio.Directory, ".audio.m4a");
            try
            {
                await Task.Run(() =>
                {
                    AudioPreprocessor.CreateAlignedStereo16k(audio.Microphone, audio.System, audio.MicrophoneOffsetMs, audio.SystemOffsetMs, temp);
                    AudioPreprocessor.EncodeAac(temp, partial);
                }, cancellationToken).ConfigureAwait(false);
                File.Move(partial, archive);
            }
            finally
            {
                File.Delete(temp);
                File.Delete(partial);
            }
        }
        foreach (var name in new[] { "mic.wav", "system.wav", ".archive-mic.wav", ".archive-system.wav" }) File.Delete(Path.Combine(audio.Directory, name));
        if (!keep && audio.Single is not null) File.Delete(audio.Single);
        var live = Path.Combine(audio.Directory, ".live");
        if (Directory.Exists(live)) Directory.Delete(live, recursive: true);
    }

    private async Task RunHookOnceAsync(string directory, CancellationToken cancellationToken)
    {
        var ledger = ReadLedger(directory);
        if (ledger.HookRan || !configReadable()) return;
        WriteLedger(directory, ledger with { HookRan = true });
        if (settings().OnStop is not { } hook || string.IsNullOrWhiteSpace(hook.Executable)) return;
        try
        {
            var info = new ProcessStartInfo(hook.Executable) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = directory };
            foreach (var argument in hook.Arguments) info.ArgumentList.Add(argument.Replace("{session}", directory, StringComparison.Ordinal));
            // A hook may open a viewer such as Notepad. Launch it once, then
            // let the queue continue while the viewer remains open.
            using var process = Process.Start(info);
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            await File.AppendAllTextAsync(Path.Combine(directory, "transcribe.log"),
                $"{DateTimeOffset.UtcNow:O} on_stop: {exception.Message}{Environment.NewLine}", cancellationToken).ConfigureAwait(false);
        }
    }

    private static bool Has(string directory, string name) => File.Exists(Path.Combine(directory, name));

    private static string? ReadText(string directory, string name)
    {
        var path = Path.Combine(directory, name);
        return File.Exists(path) && File.ReadAllText(path).Trim() is { Length: > 0 } text ? text : null;
    }

    private static ProcessingLedger ReadLedger(string directory)
    {
        var path = Path.Combine(directory, "processing.json");
        if (!File.Exists(path)) return new ProcessingLedger();
        try
        {
            return JsonSerializer.Deserialize<ProcessingLedger>(File.ReadAllText(path), LedgerOptions) ?? new ProcessingLedger();
        }
        catch (JsonException) { return new ProcessingLedger(); }
    }

    private static void WriteLedger(string directory, ProcessingLedger ledger)
    {
        var path = Path.Combine(directory, "processing.json");
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(ledger, LedgerOptions));
        File.Move(temporary, path, overwrite: true);
    }

    public static ProcessingLedger Ledger(string directory) => ReadLedger(directory);

    private static readonly JsonSerializerOptions LedgerOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private static async Task<TranscriptDocument> ReadTranscriptAsync(string directory, CancellationToken cancellationToken) =>
        JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(Path.Combine(directory, "transcript.json"), cancellationToken).ConfigureAwait(false))
        ?? throw new InvalidDataException("transcript.json is empty");

    public static async Task<string> ReadTitleAsync(string directory, CancellationToken cancellationToken)
    {
        using var meta = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "meta.json"), cancellationToken).ConfigureAwait(false));
        return meta.RootElement.TryGetProperty("title", out var value) && value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString())
            ? value.GetString()!
            : Path.GetFileName(directory);
    }

    private void Publish(string directory, string stage, string message, bool busy)
    {
        var status = new ProcessingStatus(directory, stage, message, busy);
        statuses[directory] = status;
        StatusChanged?.Invoke(this, status);
        SessionsChanged?.Invoke(this, EventArgs.Empty);
    }

    private static string KnownModel(string engine, string model) => (engine, model) switch
    {
        ("assemblyai", _) => "universal-3-pro",
        ("openai", "gpt-4o-transcribe-diarize") => "gpt-4o-transcribe-diarize",
        ("elevenlabs", _) => "scribe_v2",
        ("parakeet", _) => "parakeet-v3",
        ("gigaam", _) => "gigaam-v3",
        ("whisper", _) => "whisper-large-v3-turbo",
        _ => "custom",
    };

    private static string Reason(ProcessingFailure failure) => failure.Kind switch
    {
        FailureKind.Environmental when failure.Unreachable => "no_network",
        FailureKind.Environmental when failure.Message.Contains("key", StringComparison.OrdinalIgnoreCase)
                                       || failure.Message.Contains("ключ", StringComparison.OrdinalIgnoreCase) => "no_key",
        FailureKind.Environmental => "no_model",
        FailureKind.Transient => "usage_limit",
        _ => "unknown",
    };

    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync().ConfigureAwait(false);
        queue.Writer.TryComplete();
        if (worker is not null)
            try { await worker.ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
    }
}
