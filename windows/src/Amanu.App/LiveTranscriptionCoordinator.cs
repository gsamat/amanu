using System.IO;
using System.Diagnostics;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using Amanu.Core.Recording;
using NAudio.Wave;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

/// <summary>Recognition owns its models and never queues behind the final transcript.</summary>
public sealed class LiveTranscriptionCoordinator : IAsyncDisposable
{
    private const int FrameSamples = 35_840;
    private readonly ILiveAudioSource capture;
    private readonly ModelManager models;
    private readonly Func<AppSettings> settings;
    private readonly SemaphoreSlim transitions = new(1);
    private readonly Func<string?, int, CancellationToken, Task<ILiveSpeechWorker>> createWorker;
    private CancellationTokenSource? preparationCancellation;
    private Task<Prepared?>? preparation;
    private string? preparedLanguage;
    private string status = "";
    private CancellationTokenSource? cancellation;
    private Task worker = Task.CompletedTask;
    private Run? active;
    private long nextLine;
    private bool disposed;

    public LiveTranscriptionCoordinator(ILiveAudioSource capture, ModelManager models, Func<AppSettings> settings)
        : this(capture, models, settings, async (language, threads, token) =>
            await LiveSpeechWorker.CreateAsync(models.LiveRuntimeDirectory, models.ModelPath("nemotron-live"), language, threads, token).ConfigureAwait(false))
    {
    }

    internal LiveTranscriptionCoordinator(ILiveAudioSource capture, ModelManager models, Func<AppSettings> settings,
        Func<string?, int, CancellationToken, Task<ILiveSpeechWorker>> createWorker)
    {
        this.capture = capture;
        this.models = models;
        this.settings = settings;
        this.createWorker = createWorker;
        capture.LiveAudioAvailable += OnAudio;
        capture.CaptureStarted += OnStarted;
        capture.LiveStopping = StopAsync;
    }

    public event EventHandler<LiveLine>? LineReady;
    public event EventHandler<string>? StatusChanged;
    public event EventHandler<LiveDiagnostic>? Diagnostic;
    public string Status => Volatile.Read(ref status);
    private void SetStatus(string value)
    {
        Volatile.Write(ref status, value);
        StatusChanged?.Invoke(this, value);
    }
    private void OnStarted(object? sender, EventArgs args) => _ = RefreshAsync();

    public async Task RefreshAsync()
    {
        await transitions.WaitAsync().ConfigureAwait(false);
        try
        {
            var current = settings();
            if (disposed || !current.LiveTranscription.Enabled || !current.Transcription.Enabled)
            {
                await StopCoreAsync().ConfigureAwait(false);
                await ClearPreparationAsync().ConfigureAwait(false);
                SetStatus("");
                return;
            }
            if (!models.IsReady("nemotron-live"))
            {
                await StopCoreAsync().ConfigureAwait(false);
                await ClearPreparationAsync().ConfigureAwait(false);
                SetStatus(T("Download the live model in Settings", "Скачайте модель лайва в настройках"));
                return;
            }
            var language = MeetingLanguages.Pin(MeetingLanguages.Expected(current.Transcription.Language)) is "en" ? "en-US" : null;
            if (preparation is null || preparedLanguage != language
                || (preparation.IsCompletedSuccessfully && preparation.Result is not { Healthy: true }))
            {
                await StopCoreAsync().ConfigureAwait(false);
                await ClearPreparationAsync().ConfigureAwait(false);
                preparedLanguage = language;
                preparationCancellation = new CancellationTokenSource();
                var token = preparationCancellation.Token;
                SetStatus(T("loading…", "загрузка…"));
                preparation = Task.Run(() => PrepareAsync(language, token));
            }
            if (capture.IsRunning && cancellation is null)
            {
                cancellation = new CancellationTokenSource();
                worker = RunAsync(cancellation, preparation);
            }
        }
        finally { transitions.Release(); }
    }

    private async Task<Prepared?> PrepareAsync(string? language, CancellationToken token)
    {
        ILiveSpeechWorker? mic = null;
        ILiveSpeechWorker? system = null;
        try
        {
            // Loading uses the CPU, but warm idle decoders must not block final transcripts.
            using var cpu = await models.CpuTranscription.EnterLiveAsync(token).ConfigureAwait(false);
            var threads = Math.Clamp(Environment.ProcessorCount / 4, 1, 4);
            mic = await createWorker(language, threads, token).ConfigureAwait(false);
            system = await createWorker(language, threads, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (!capture.IsRunning) SetStatus(T("ready", "готово"));
            return new Prepared(mic, system);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception)
        {
            SetStatus(T("live unavailable: ", "лайв недоступен: ") + exception.Message);
        }
        if (system is not null) await system.DisposeAsync().ConfigureAwait(false);
        if (mic is not null) await mic.DisposeAsync().ConfigureAwait(false);
        return null;
    }

    private async Task RunAsync(CancellationTokenSource source, Task<Prepared?> prepared)
    {
        var token = source.Token;
        Prepared? decoders = null;
        try
        {
            decoders = await prepared.WaitAsync(token).ConfigureAwait(false);
            if (decoders is null) return;
            using var cpu = await models.CpuTranscription.EnterLiveAsync(token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            var mic = decoders.Mic;
            var system = decoders.System;
            var run = new Run(source);
            Volatile.Write(ref active, run);
            SetStatus(T("live", "в реальном времени"));
            await Task.WhenAll(ConsumeAsync(run, run.Mic, mic, SpeakerLabels.Me),
                ConsumeAsync(run, run.System, system, SpeakerLabels.Them)).ConfigureAwait(false);
            // A fresh session must never inherit the previous session's decoder state.
            using var reset = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await mic.CommandAsync(2, reset.Token).ConfigureAwait(false);
            await system.CommandAsync(2, reset.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            if (decoders is not null) decoders.Invalid = true;
        }
        catch (Exception exception)
        {
            if (decoders is not null) decoders.Invalid = true;
            source.Cancel();
            SetStatus(T("live stopped · recording continues: ", "лайв остановлен · запись продолжается: ") + exception.Message);
        }
        finally { Volatile.Write(ref active, null); }
    }

    private void OnAudio(bool microphone, ReadOnlySpan<byte> data, WaveFormat format, bool silent, long offsetMs)
    {
        var run = Volatile.Read(ref active);
        if (run is null || run.Source.IsCancellationRequested || Volatile.Read(ref run.Stopping) != 0) return;
        var count = (int)((long)(data.Length / format.BlockAlign) * 16000 / format.SampleRate);
        var queue = microphone ? run.Mic : run.System;
        if (!queue.TryWrite(new Packet(data.ToArray(), format, silent, offsetMs), count)
            && Volatile.Read(ref run.Stopping) == 0) Overloaded(run, microphone ? SpeakerLabels.Me : SpeakerLabels.Them, "queue capacity", capture.ElapsedMs - offsetMs);
    }

    private void Overloaded(Run run, string speaker, string reason, long lag)
    {
        if (Interlocked.Exchange(ref run.Overloaded, 1) != 0) return;
        Diagnostic?.Invoke(this, new LiveDiagnostic(speaker, reason, 0, lag));
        try { run.Source.Cancel(); } catch (ObjectDisposedException) { return; }
        SetStatus(T("live stopped: can't keep up · recording continues", "лайв остановлен: не успеваю · запись продолжается"));
    }

    private async Task ConsumeAsync(Run run, LiveAudioQueue<Packet> queue, ILiveSpeechWorker stream, string speaker)
    {
        var token = run.Source.Token;
        LiveAudioResampler? resampler = null;
        WaveFormat? format = null;
        var frame = new float[FrameSamples];
        var filled = 0;
        var previousEnd = 0L;
        var frameAt = 0L;
        var decodedThroughMs = 0L;
        var utteranceAt = 0L;
        var utteranceSamples = 0;
        var silentSamples = 0;
        var text = "";
        var id = 0L;
        async Task FeedAsync(int count, CancellationToken cancellation)
        {
            var watch = Stopwatch.StartNew();
            await stream.FeedAsync(frame, count, cancellation).ConfigureAwait(false);
            Diagnostic?.Invoke(this, new LiveDiagnostic(speaker, "feed", watch.ElapsedMilliseconds, capture.ElapsedMs - frameAt - count * 1000L / 16000));
        }
        async Task CommandAsync(byte command, CancellationToken cancellation)
        {
            var watch = Stopwatch.StartNew();
            await stream.CommandAsync(command, cancellation).ConfigureAwait(false);
            Diagnostic?.Invoke(this, new LiveDiagnostic(speaker, command == 1 ? "finalize" : "reset", watch.ElapsedMilliseconds, capture.ElapsedMs - decodedThroughMs));
        }
        void Publish(bool final)
        {
            var next = stream.Text;
            if (next.Length == 0) return;
            if (id == 0) id = Interlocked.Increment(ref nextLine);
            text = next;
            LineReady?.Invoke(this, new LiveLine(id, TimeSpan.FromMilliseconds(utteranceAt), speaker, text, final, decodedThroughMs));
        }
        async Task CloseUtteranceAsync()
        {
            await CommandAsync(1, token).ConfigureAwait(false);
            Publish(true);
            await CommandAsync(2, token).ConfigureAwait(false);
            text = "";
            id = 0;
            silentSamples = utteranceSamples = 0;
        }
        try
        {
            await foreach (var packet in queue.ReadAllAsync(token).ConfigureAwait(false))
            {
                if (Volatile.Read(ref run.Stopping) != 0) break;
                if (capture.ElapsedMs - packet.OffsetMs > 5000) { Overloaded(run, speaker, "packet age", capture.ElapsedMs - packet.OffsetMs); break; }
                // Loopback sends no packets in silence; close the block on its next packet.
                if (previousEnd > 0 && packet.OffsetMs - previousEnd > 2000)
                {
                    if (filled > 0 && (utteranceSamples > 0 || HasAudibleAudio(frame.AsSpan(0, filled))))
                    {
                        if (utteranceSamples == 0) utteranceAt = frameAt;
                        await FeedAsync(filled, token).ConfigureAwait(false);
                        decodedThroughMs = frameAt + filled * 1000L / 16000;
                    }
                    await CloseUtteranceAsync().ConfigureAwait(false);
                    filled = 0;
                }
                if (!Equals(format, packet.Format)) { resampler = new LiveAudioResampler(packet.Format); format = packet.Format; }
                var samples = resampler!.Convert(packet.Data, packet.Silent);
                previousEnd = packet.OffsetMs + packet.Data.Length * 1000L / packet.Format.AverageBytesPerSecond;
                var offset = 0;
                while (offset < samples.Length)
                {
                    token.ThrowIfCancellationRequested();
                    if (filled == 0) frameAt = packet.OffsetMs + offset * 1000L / 16000;
                    var copy = Math.Min(FrameSamples - filled, samples.Length - offset);
                    samples.AsSpan(offset, copy).CopyTo(frame.AsSpan(filled));
                    filled += copy;
                    offset += copy;
                    if (filled < FrameSamples) continue;
                    // An idle decoder must not run language detection on endless
                    // silence. Keep the whole first audible frame, including its
                    // leading audio; the durable recorder receives every packet.
                    if (utteranceSamples == 0 && !HasAudibleAudio(frame.AsSpan(0, filled)))
                    {
                        filled = 0;
                        continue;
                    }
                    if (utteranceSamples == 0) utteranceAt = frameAt;
                    await FeedAsync(frame.Length, token).ConfigureAwait(false);
                    decodedThroughMs = frameAt + FrameSamples * 1000L / 16000;
                    filled = 0;
                    utteranceSamples += FrameSamples;
                    var next = stream.Text;
                    silentSamples = next != text ? 0 : silentSamples + FrameSamples;
                    if (next != text) Publish(false);
                    if ((text.Length > 0 && silentSamples >= 32000) || utteranceSamples >= 960000) await CloseUtteranceAsync().ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { run.Source.Cancel(); throw; }
        finally
        {
            // Finalize the small decoder tail, without replaying the old queued packets at Stop.
            if (run.Overloaded == 0 && stream.Healthy)
            {
                using var finish = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                try
                {
                    if (filled > 0 && (utteranceSamples > 0 || HasAudibleAudio(frame.AsSpan(0, filled))))
                    {
                        if (utteranceSamples == 0) utteranceAt = frameAt;
                        await FeedAsync(filled, finish.Token).ConfigureAwait(false);
                        decodedThroughMs = frameAt + filled * 1000L / 16000;
                    }
                    await CommandAsync(1, finish.Token).ConfigureAwait(false);
                    Publish(true);
                }
                catch (Exception exception) when (exception is OperationCanceledException or IOException) { }
            }
        }
    }

    public async Task StopAsync()
    {
        await transitions.WaitAsync().ConfigureAwait(false);
        try { await StopCoreAsync().ConfigureAwait(false); }
        finally { transitions.Release(); }
    }

    public static bool HasAudibleAudio(ReadOnlySpan<float> samples)
    {
        double energy = 0;
        foreach (var sample in samples) energy += sample * sample;
        return energy > samples.Length * 0.00000001; // RMS above -80 dBFS; preserve very quiet speech.
    }
    private async Task StopCoreAsync()
    {
        var run = Interlocked.Exchange(ref active, null);
        if (cancellation is null) return;
        if (run is not null && !cancellation.IsCancellationRequested)
        {
            // Finish the in-flight decoder call and its short tail. Skip queued
            // packets, and cancel a stuck decoder after a bounded grace period.
            Interlocked.Exchange(ref run.Stopping, 1);
            run.Mic.Complete();
            run.System.Complete();
            try { await worker.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); }
            catch (TimeoutException) { await cancellation.CancelAsync().ConfigureAwait(false); }
        }
        else await cancellation.CancelAsync().ConfigureAwait(false);
        await worker.ConfigureAwait(false); // Release the CPU before handing the session to final processing.
        cancellation.Dispose();
        cancellation = null;
        if (preparation is { IsCompletedSuccessfully: true } && preparation.Result is { Healthy: true })
            SetStatus(T("ready", "готово"));
    }
    private async Task ClearPreparationAsync()
    {
        if (preparationCancellation is null) return;
        await preparationCancellation.CancelAsync().ConfigureAwait(false);
        var decoders = await preparation!.ConfigureAwait(false);
        if (decoders is not null) await decoders.DisposeAsync().ConfigureAwait(false);
        preparationCancellation.Dispose();
        preparationCancellation = null;
        preparation = null;
    }
    public async ValueTask DisposeAsync()
    {
        disposed = true;
        capture.LiveAudioAvailable -= OnAudio;
        capture.CaptureStarted -= OnStarted;
        capture.LiveStopping = null;
        await RefreshAsync().ConfigureAwait(false);
    }
    private sealed record Prepared(ILiveSpeechWorker Mic, ILiveSpeechWorker System) : IAsyncDisposable
    {
        public bool Invalid;
        public bool Healthy => !Invalid && Mic.Healthy && System.Healthy;
        public async ValueTask DisposeAsync()
        {
            await System.DisposeAsync().ConfigureAwait(false);
            await Mic.DisposeAsync().ConfigureAwait(false);
        }
    }
    private sealed record Packet(byte[] Data, WaveFormat Format, bool Silent, long OffsetMs);
    private sealed class Run(CancellationTokenSource source)
    {
        public CancellationTokenSource Source { get; } = source;
        public LiveAudioQueue<Packet> Mic { get; } = new(80000);
        public LiveAudioQueue<Packet> System { get; } = new(80000);
        public int Overloaded;
        public int Stopping;
    }
}

public sealed record LiveLine(long Id, TimeSpan At, string Speaker, string Text, bool IsFinal, long AudioThroughMs);
public sealed record LiveDiagnostic(string Speaker, string Stage, long DurationMs, long LagMs);
