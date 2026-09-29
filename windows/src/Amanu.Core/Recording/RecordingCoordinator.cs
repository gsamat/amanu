using Amanu.Core.Sessions;

namespace Amanu.Core.Recording;

public sealed record CaptureStopResult(int MicrophoneOffsetMs, int SystemOffsetMs);

public interface IAudioCapture : IAsyncDisposable
{
    Task StartAsync(
        SessionHandle session,
        string? processFamily,
        CancellationToken cancellationToken);

    Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken);
    Task SetPausedAsync(bool paused, CancellationToken cancellationToken);
}

public sealed record RecordingState(
    bool IsRecording,
    bool IsPaused,
    DateTimeOffset? StartedAt,
    string? SessionDirectory,
    SessionTrigger? Trigger,
    string Status)
{
    public static RecordingState Ready { get; } = new(
        false, false, null, null, null, "Ready");
}

public sealed class RecordingCoordinator(
    SessionStore sessions,
    AutoRecordPolicy autoRecord,
    IAudioCapture capture) : IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private SessionHandle? current;
    private DateTimeOffset? pausedAt;
    private TimeSpan pausedFor;

    public RecordingState State { get; private set; } = RecordingState.Ready;

    public event EventHandler<RecordingState>? StateChanged;
    public event EventHandler<SessionHandle>? SessionCompleted;

    public void SetAutoRecordEnabled(bool enabled) => autoRecord.SetEnabled(enabled);

    public async Task StartManualAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current is not null)
            {
                return;
            }
            await StartCoreAsync(now, SessionTrigger.Manual, null, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task ObserveAsync(
        AudioObservation observation,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var decision = autoRecord.Observe(observation);
            if (decision == AutoRecordDecision.Start && current is null)
            {
                await StartCoreAsync(
                    observation.At,
                    SessionTrigger.MicrophoneActivity,
                    observation.MicrophoneOwner,
                    cancellationToken).ConfigureAwait(false);
            }
            else if (decision == AutoRecordDecision.Stop && current is not null)
            {
                await StopCoreAsync(observation.At, "automatic", cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task StopAsync(
        DateTimeOffset now,
        string reason,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current is null)
            {
                return;
            }
            await StopCoreAsync(now, reason, cancellationToken).ConfigureAwait(false);
            if (reason == "manual")
            {
                autoRecord.ManualStop(now);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task TogglePauseAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current is null) return;
            var paused = !State.IsPaused;
            await capture.SetPausedAsync(paused, cancellationToken).ConfigureAwait(false);
            if (paused) pausedAt = DateTimeOffset.UtcNow;
            else if (pausedAt is { } started) { pausedFor += DateTimeOffset.UtcNow - started; pausedAt = null; }
            Publish(State with { IsPaused = paused, Status = paused ? "Recording paused" : "Recording" });
        }
        finally { gate.Release(); }
    }

    private async Task StartCoreAsync(
        DateTimeOffset now,
        SessionTrigger trigger,
        string? processFamily,
        CancellationToken cancellationToken)
    {
        var session = sessions.Start(now, null, trigger, processFamily);
        try
        {
            await capture.StartAsync(session, processFamily, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            sessions.Complete(session, DateTimeOffset.Now, "capture-error", 0, 0);
            Publish(RecordingState.Ready);
            throw;
        }
        current = session;
        pausedAt = null;
        pausedFor = TimeSpan.Zero;
        autoRecord.RecordingStarted(now, trigger == SessionTrigger.Manual);
        Publish(new RecordingState(
            true, false, now, session.Directory, trigger,
            trigger == SessionTrigger.Manual ? "Recording manually" : $"Recording {processFamily}"));
    }

    private async Task StopCoreAsync(
        DateTimeOffset now,
        string reason,
        CancellationToken cancellationToken)
    {
        var session = current!;
        var result = await capture.StopAsync(cancellationToken).ConfigureAwait(false);
        if (pausedAt is { } pausedSince) pausedFor += DateTimeOffset.UtcNow - pausedSince;
        sessions.Complete(
            session, now, reason, result.MicrophoneOffsetMs, result.SystemOffsetMs,
            Math.Max(0, (int)pausedFor.TotalSeconds));
        SessionCompleted?.Invoke(this, session);
        current = null;
        pausedAt = null;
        pausedFor = TimeSpan.Zero;
        autoRecord.RecordingStopped();
        Publish(RecordingState.Ready);
    }

    private void Publish(RecordingState state)
    {
        State = state;
        StateChanged?.Invoke(this, state);
    }

    public async ValueTask DisposeAsync()
    {
        gate.Dispose();
        await capture.DisposeAsync().ConfigureAwait(false);
    }
}
