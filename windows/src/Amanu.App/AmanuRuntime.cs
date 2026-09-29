using System.Diagnostics;
using System.IO;
using Amanu.Core.Configuration;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;
using Amanu.Core.Processing;
using System.Net.Http;
using System.Text.Json;

namespace Amanu.App;

public sealed class AmanuRuntime : IAsyncDisposable
{
    private readonly AppSettingsStore settingsStore;
    private readonly RecordingCoordinator coordinator;
    private readonly CallActivityMonitor activityMonitor;
    private readonly HttpClient httpClient;
    private readonly SecretStore secrets;
    private readonly ModelManager models;
    private readonly ProcessingCoordinator processing;
    private readonly WindowsAudioCapture capture;
    private readonly LiveTranscriptionCoordinator liveTranscription;
    private readonly AnalyticsService analytics;
    private readonly CancellationTokenSource lifetime = new();
    private TrayIconService? tray;
    private bool disposed;

    private AmanuRuntime(
        string configPath,
        string setupPath,
        AppSettingsStore settingsStore,
        AppSettings settings,
        RecordingCoordinator coordinator,
        CallActivityMonitor activityMonitor,
        HttpClient httpClient,
        SecretStore secrets,
        ModelManager models,
        ProcessingCoordinator processing,
        WindowsAudioCapture capture,
        LiveTranscriptionCoordinator liveTranscription,
        AnalyticsService analytics,
        int recoveredSessionCount)
    {
        ConfigPath = configPath;
        SetupPath = setupPath;
        this.settingsStore = settingsStore;
        Settings = settings;
        this.coordinator = coordinator;
        this.activityMonitor = activityMonitor;
        this.httpClient = httpClient;
        this.secrets = secrets;
        this.models = models;
        this.processing = processing;
        this.capture = capture;
        this.liveTranscription = liveTranscription;
        this.analytics = analytics;
        RecoveredSessionCount = recoveredSessionCount;
        coordinator.StateChanged += (_, state) =>
        {
            StateChanged?.Invoke(this, state);
            if (state.IsRecording)
                _ = analytics.RecordAsync("recording_started", new Dictionary<string, object?>
                {
                    ["trigger"] = state.Trigger == SessionTrigger.Manual ? "manual" : "mic-activity",
                });
        };
        coordinator.SessionCompleted += (_, session) =>
        {
            processing.Enqueue(session.Directory);
            _ = analytics.RecordAsync("recording_finished", new Dictionary<string, object?>
            {
                ["trigger"] = session.Trigger == SessionTrigger.Manual ? "manual" : "mic-activity",
                ["duration_bucket"] = Amanu.Core.Analytics.AnalyticsPolicy.DurationBucket((DateTimeOffset.Now - session.StartedAt).TotalSeconds),
                ["live_used"] = Settings.LiveTranscription.Enabled,
                ["system_audio"] = File.Exists(session.SystemTrack) && new FileInfo(session.SystemTrack).Length > 44,
            });
        };
        processing.StatusChanged += (_, status) =>
        {
            ProcessingStatusChanged?.Invoke(this, status);
            if (status.Stage == "complete") tray?.ShowNotification("Amanu", status.Message);
            else if (status.Stage == "failed") tray?.ShowNotification("Amanu — ошибка обработки", status.Message, System.Windows.Forms.ToolTipIcon.Error);
        };
        processing.SessionsChanged += (_, _) => SessionsChanged?.Invoke(this, EventArgs.Empty);
        models.Progress += (_, progress) => DownloadProgressChanged?.Invoke(this, progress);
        models.DownloadStarted += (_, item) => _ = analytics.RecordAsync("model_download_started", new Dictionary<string, object?> { ["asset"] = AnalyticsAsset(item) });
        models.DownloadFinished += (_, item) => _ = analytics.RecordAsync("model_download_finished", new Dictionary<string, object?> { ["asset"] = AnalyticsAsset(item) });
        models.DownloadFailed += (_, item) => _ = analytics.RecordAsync("model_download_failed", new Dictionary<string, object?> { ["asset"] = AnalyticsAsset(item), ["reason"] = "unknown" });
        liveTranscription.TextChanged += (_, text) => LiveTranscriptChanged?.Invoke(this, text);
    }

    public string ConfigPath { get; }
    public string SetupPath { get; }
    public bool IsSetupComplete => File.Exists(SetupPath);
    public AppSettings Settings { get; }
    public int RecoveredSessionCount { get; }
    public RecordingState State => coordinator.State;

    public event EventHandler<RecordingState>? StateChanged;
    public event EventHandler<ProcessingStatus>? ProcessingStatusChanged;
    public event EventHandler<DownloadProgress>? DownloadProgressChanged;
    public event EventHandler? SessionsChanged;
    public event EventHandler<string>? LiveTranscriptChanged;

    public static AmanuRuntime Create()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        var configPath = Path.Combine(localData, "Amanu", "config.json");
        var setupPath = Path.Combine(localData, "Amanu", "setup.json");
        var settingsStore = new AppSettingsStore(configPath, documents);
        var settings = settingsStore.Load();
        Directory.CreateDirectory(settings.RecordingsDirectory);

        var sessionStore = new SessionStore(settings.RecordingsDirectory, Environment.ProcessId);
        var recovered = sessionStore.RecoverInterrupted(DateTimeOffset.Now, ProcessIsAlive);
        var options = new AutoRecordOptions(
            settings.AutoRecord.Enabled,
            TimeSpan.FromSeconds(settings.AutoRecord.StartDelaySeconds),
            TimeSpan.FromSeconds(settings.AutoRecord.StopDelaySeconds),
            TimeSpan.FromSeconds(settings.AutoRecord.MinimumDurationSeconds),
            TimeSpan.FromMinutes(settings.AutoRecord.SilenceStopMinutes),
            TimeSpan.FromMinutes(settings.AutoRecord.MaximumDurationMinutes));
        var policy = new AutoRecordPolicy(options);
        var capture = new WindowsAudioCapture { LiveChunksEnabled = settings.LiveTranscription.Enabled };
        var coordinator = new RecordingCoordinator(sessionStore, policy, capture);
        var matcher = new CallProcessMatcher(
            settings.AutoRecord.CallProcesses,
            settings.AutoRecord.IgnoreProcesses);
        var monitor = new CallActivityMonitor(matcher);
        var httpClient = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("Amanu-Windows/0.6");
        var secrets = new SecretStore();
        var models = new ModelManager(Path.Combine(localData, "Amanu"), httpClient);
        var analytics = new AnalyticsService(Path.Combine(localData, "Amanu"), settings, httpClient);
        var processing = new ProcessingCoordinator(settings, secrets, models, httpClient, analytics);
        var liveTranscription = new LiveTranscriptionCoordinator(capture, settings, secrets, models, httpClient);
        return new AmanuRuntime(
            configPath,
            setupPath,
            settingsStore,
            settings,
            coordinator,
            monitor,
            httpClient,
            secrets,
            models,
            processing,
            capture,
            liveTranscription,
            analytics,
            recovered.Count);
    }

    public void AttachWindow(CompactWindow window)
    {
        tray = new TrayIconService(window, this, Settings.TrayIcon);
    }

    public async Task StartAsync()
    {
        StartupRegistration.SetEnabled(Settings.StartAtLogin);
        try { await analytics.StartAsync(lifetime.Token); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { }
        processing.Start();
        _ = ObserveCallsAsync(lifetime.Token);
        _ = UpdateService.DownloadPendingUpdateAsync(() => State.IsRecording, lifetime.Token);
    }

    public async Task StartManualAsync()
    {
        try { await coordinator.StartManualAsync(DateTimeOffset.Now); }
        catch
        {
            _ = analytics.RecordAsync("recording_start_failed", new Dictionary<string, object?>
            {
                ["trigger"] = "manual", ["component"] = "unknown", ["reason"] = "unknown",
            });
            throw;
        }
    }

    public Task StopManualAsync() => coordinator.StopAsync(DateTimeOffset.Now, "manual");

    public Task TogglePauseAsync() => coordinator.TogglePauseAsync();

    public async Task StopForExitAsync()
    {
        if (State.IsRecording)
        {
            await coordinator.StopAsync(DateTimeOffset.Now, "quit");
        }
    }

    public void SetAutoRecord(bool enabled)
    {
        coordinator.SetAutoRecordEnabled(enabled);
        Settings.AutoRecord.Enabled = enabled;
        settingsStore.Save(Settings);
    }

    public void SetStartAtLogin(bool enabled)
    {
        StartupRegistration.SetEnabled(enabled);
        Settings.StartAtLogin = enabled;
        settingsStore.Save(Settings);
    }

    public void SaveSettings()
    {
        capture.LiveChunksEnabled = Settings.LiveTranscription.Enabled;
        tray?.SetVisible(Settings.TrayIcon);
        settingsStore.Save(Settings);
        _ = analytics.SetEnabledAsync(Settings.Analytics);
    }

    public string? GetSecret(string name) => secrets.Get(name);

    public void SetSecret(string name, string? value) => secrets.Set(name, value);

    public Task<IReadOnlyList<SessionListItem>> LoadSessionsAsync(CancellationToken cancellationToken = default) =>
        SessionInventory.ScanAsync(Settings.RecordingsDirectory, cancellationToken);

    public Task<string> ImportAsync(string source, CancellationToken cancellationToken = default) =>
        processing.ImportAsync(source, cancellationToken);

    public void RetryProcessing(string directory, bool retranscribe) => processing.Retry(directory, retranscribe);

    public Task SetSpeakerNameAsync(string directory, string label, string name, CancellationToken cancellationToken = default) =>
        processing.SetSpeakerNameAsync(directory, label, name, cancellationToken);

    public Task EnsureLocalModelAsync(string model, CancellationToken cancellationToken = default) =>
        processing.EnsureLocalModelAsync(model, cancellationToken);

    public Task CompleteSetupAsync(CancellationToken cancellationToken = default) =>
        AtomicFiles.WriteJsonAsync(SetupPath, new { version = 1, completed_at = DateTimeOffset.UtcNow }, cancellationToken);

    public bool IsLocalModelReady(string model) => models.IsReady(model);

    public void TrackArtifact(string artifact) =>
        _ = analytics.RecordAsync("artifact_opened", new Dictionary<string, object?> { ["artifact"] = artifact });

    public void TrackSettingsOpened() => _ = analytics.RecordAsync("settings_opened");

    private async Task ObserveCallsAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                try
                {
                    if ((!Settings.AutoRecord.Enabled || !Settings.AutoRecord.MicrophoneActivity) && !State.IsRecording)
                        continue;

                    var observation = activityMonitor.Observe(DateTimeOffset.Now);
                    await coordinator.ObserveAsync(observation, cancellationToken);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    StateChanged?.Invoke(this, State with { Status = $"Monitoring error: {exception.Message}" });
                    _ = analytics.RecordAsync("recording_start_failed", new Dictionary<string, object?>
                    {
                        ["trigger"] = "mic-activity", ["component"] = "unknown", ["reason"] = "unknown",
                    });
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private static bool ProcessIsAlive(int processId)
    {
        try
        {
            return !Process.GetProcessById(processId).HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static string AnalyticsAsset(string item) => item.ToLowerInvariant() switch
    {
        "local runtime" => "runtime",
        "model parakeet" => "parakeet-v3",
        "model gigaam" => "gigaam-v3",
        "model whisper" => "whisper-large-v3-turbo",
        _ => "runtime",
    };

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        lifetime.Cancel();
        tray?.Dispose();
        activityMonitor.Dispose();
        await liveTranscription.DisposeAsync();
        await processing.DisposeAsync();
        await coordinator.DisposeAsync();
        await analytics.DisposeAsync();
        httpClient.Dispose();
        lifetime.Dispose();
    }
}
