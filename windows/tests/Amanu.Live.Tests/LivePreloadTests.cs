using System.Collections.Concurrent;
using System.IO;
using System.Net.Http;
using Amanu.App;
using Amanu.Core.Configuration;
using NAudio.Wave;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class LivePreloadTests
{
    [Fact]
    public async Task Enabled_live_preloads_while_idle_and_reuses_decoders_across_recordings()
    {
        await using var fixture = new Fixture();
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("ready");
        Assert.False(fixture.Source.IsRunning);
        Assert.Equal(2, fixture.Workers.Count);
        Assert.All(fixture.Workers, worker => Assert.Empty(worker.Commands));
        using (await fixture.Models.CpuTranscription.EnterBatchAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2))) { }

        for (var recording = 0; recording < 2; recording++)
        {
            fixture.Source.Start();
            await fixture.WaitStatus("live");
            var line = new TaskCompletionSource<LiveLine>(TaskCreationOptions.RunContinuationsAsynchronously);
            void OnLine(object? sender, LiveLine value) => line.TrySetResult(value);
            fixture.Live.LineReady += OnLine;
            fixture.Source.Speech();
            var recognized = await line.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.Equal("speech", recognized.Text);
            fixture.Live.LineReady -= OnLine;
            await fixture.Source.Stop();
            Assert.Equal("ready", fixture.Live.Status);
            Assert.Equal(2, fixture.Workers.Count);
            using (await fixture.Models.CpuTranscription.EnterBatchAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2))) { }
            Assert.All(fixture.Workers, worker => Assert.Equal("", worker.Text));
        }
        Assert.Equal(1, fixture.Statuses.Count(status => status == "loading…"));
        fixture.Settings.LiveTranscription.Enabled = false;
        await fixture.Live.RefreshAsync();
        Assert.All(fixture.Workers, worker => Assert.True(worker.Disposed));
        Assert.Equal("", fixture.Live.Status);
    }

    [Fact]
    public async Task Recording_started_during_preload_shares_the_pending_load()
    {
        await using var fixture = new Fixture();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.BeforeCreate = token => release.Task.WaitAsync(token);
        await fixture.Live.RefreshAsync();
        fixture.Source.Start();
        await fixture.Live.RefreshAsync();
        release.SetResult();
        await fixture.WaitStatus("live");
        Assert.Equal(2, fixture.Workers.Count);
        await fixture.Source.Stop();
    }

    [Fact]
    public async Task Disable_cancels_preload_and_releases_partially_loaded_decoder()
    {
        await using var fixture = new Fixture();
        var secondLoad = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.BeforeCreate = async token =>
        {
            if (fixture.Workers.Count == 0) return;
            secondLoad.SetResult();
            await Task.Delay(Timeout.Infinite, token);
        };
        await fixture.Live.RefreshAsync();
        await secondLoad.Task.WaitAsync(TimeSpan.FromSeconds(2));
        fixture.Settings.LiveTranscription.Enabled = false;
        await fixture.Live.RefreshAsync().WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(Assert.Single(fixture.Workers).Disposed);
        using (await fixture.Models.CpuTranscription.EnterBatchAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2))) { }
        fixture.BeforeCreate = null;
        fixture.Settings.LiveTranscription.Enabled = true;
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("ready");
        Assert.Equal(3, fixture.Workers.Count);
    }

    [Fact]
    public async Task Language_change_reloads_idle_decoders_but_repeated_refresh_does_not()
    {
        await using var fixture = new Fixture();
        fixture.Settings.Transcription.Language = "en";
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("ready");
        await fixture.Live.RefreshAsync();
        Assert.Equal(2, fixture.Workers.Count);
        Assert.All(fixture.Workers, worker => Assert.Equal("en-US", worker.Language));
        fixture.Settings.Transcription.Language = "auto";
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("ready");
        Assert.All(fixture.Workers.Take(2), worker => Assert.True(worker.Disposed));
        Assert.All(fixture.Workers.Skip(2), worker => Assert.Null(worker.Language));
        Assert.Equal(4, fixture.Workers.Count);
    }

    [Theory]
    [InlineData(false, true, true)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    public async Task Disabled_transcription_or_missing_model_does_not_preload(bool live, bool transcription, bool model)
    {
        await using var fixture = new Fixture();
        fixture.Settings.LiveTranscription.Enabled = live;
        fixture.Settings.Transcription.Enabled = transcription;
        if (!model) File.Delete(fixture.Models.ModelPath("nemotron-live"));
        await fixture.Live.RefreshAsync();
        Assert.Empty(fixture.Workers);
        if (live && transcription) Assert.Contains("Download", fixture.Live.Status);
    }

    [Fact]
    public async Task Failed_preload_can_retry_and_disposal_releases_warm_decoders()
    {
        await using var fixture = new Fixture();
        fixture.BeforeCreate = _ => throw new IOException("load failed");
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("live unavailable: load failed");
        // Wait for the failed preparation to relinquish its CPU lease.
        using (await fixture.Models.CpuTranscription.EnterBatchAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2))) { }
        fixture.BeforeCreate = null;
        await fixture.Live.RefreshAsync();
        await fixture.WaitStatus("ready");
        await fixture.Live.DisposeAsync();
        Assert.All(fixture.Workers, worker => Assert.True(worker.Disposed));
        Assert.Null(fixture.Source.LiveStopping);
    }

    private sealed class Fixture : IAsyncDisposable
    {
        private readonly string directory = Path.Combine(Path.GetTempPath(), "amanu-preload-" + Guid.NewGuid());
        private readonly HttpClient http = new();
        public AppSettings Settings { get; } = new();
        public Source Source { get; } = new();
        public ModelManager Models { get; }
        public LiveTranscriptionCoordinator Live { get; }
        public ConcurrentQueue<Decoder> Workers { get; } = new();
        public ConcurrentQueue<string> Statuses { get; } = new();
        public Func<CancellationToken, Task>? BeforeCreate { get; set; }
        public Fixture()
        {
            Settings.LiveTranscription.Enabled = Settings.Transcription.Enabled = true;
            Models = new ModelManager(directory, http, directory);
            Directory.CreateDirectory(Models.LiveRuntimeDirectory);
            Directory.CreateDirectory(Models.ModelDirectory);
            File.WriteAllText(Path.Combine(Models.LiveRuntimeDirectory, "transcribe.dll"), "test");
            File.WriteAllText(Models.ModelPath("nemotron-live"), "test");
            Live = new LiveTranscriptionCoordinator(Source, Models, () => Settings, async (language, _, token) =>
            {
                if (BeforeCreate is not null) await BeforeCreate(token);
                var decoder = new Decoder(language);
                Workers.Enqueue(decoder);
                return decoder;
            });
            Live.StatusChanged += (_, status) => Statuses.Enqueue(status);
        }
        public async Task WaitStatus(string status)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            while (Live.Status != status) await Task.Delay(10, timeout.Token);
        }
        public async ValueTask DisposeAsync()
        {
            await Live.DisposeAsync();
            http.Dispose();
            Directory.Delete(directory, true);
        }
    }

    private sealed class Decoder(string? language) : ILiveSpeechWorker
    {
        public string? Language => language;
        public string Text { get; private set; } = "";
        public bool Healthy => !Disposed;
        public bool Disposed { get; private set; }
        public List<byte> Commands { get; } = [];
        public Task FeedAsync(float[] samples, int count, CancellationToken token)
        {
            Text = "speech";
            return Task.CompletedTask;
        }
        public Task CommandAsync(byte command, CancellationToken token)
        {
            Commands.Add(command);
            if (command == 2) Text = "";
            return Task.CompletedTask;
        }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }

    private sealed class Source : ILiveAudioSource
    {
        public bool IsRunning { get; private set; }
        public long ElapsedMs => 0;
        public event LiveAudioHandler? LiveAudioAvailable;
        public event EventHandler? CaptureStarted;
        public Func<Task>? LiveStopping { get; set; }
        public void Start() { IsRunning = true; CaptureStarted?.Invoke(this, EventArgs.Empty); }
        public async Task Stop() { if (LiveStopping is { } stop) await stop(); IsRunning = false; }
        public void Speech()
        {
            // Resampling has a short filter tail; supply more than one decoder frame.
            var samples = Enumerable.Repeat(0.1f, 36_000).ToArray();
            var bytes = new byte[samples.Length * sizeof(float)];
            Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
            LiveAudioAvailable?.Invoke(true, bytes, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1), false, 0);
        }
    }
}
