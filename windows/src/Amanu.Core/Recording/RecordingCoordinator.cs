using Amanu.Core.Sessions;

namespace Amanu.Core.Recording;

public sealed record CaptureStopResult(int MicrophoneOffsetMs, int SystemOffsetMs);

public interface IAudioCapture : IAsyncDisposable
{
    /// <param name="processFamily">The call app whose audio to capture, or null for everything Windows plays.</param>
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
    string? ProcessFamily)
{
    public static RecordingState Ready { get; } = new(false, false, null, null, null, null);
}

/// <summary>A recording that ended, and what became of it.</summary>
/// <param name="Discarded">Too short to have been a meeting, and deleted.</param>
/// <param name="Settled">
/// False when meta.json could not be written. The session then keeps its
/// in-progress marker and stays out of the queue, for recovery to adopt at the
/// next launch rather than a "transcription failed" banner now.
/// </param>
public sealed record CompletedRecording(SessionHandle Session, string Reason, bool Discarded, bool Settled);

public sealed class RecordingCoordinator(
    SessionStore sessions,
    AutoRecordPolicy autoRecord,
    IAudioCapture capture,
    Func<bool>? wholeSystemAudio = null) : IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private SessionHandle? current;
    private DateTimeOffset? pausedAt;
    private TimeSpan pausedFor;
    private DateTimeOffset? lastTick;

    public RecordingState State { get; private set; } = RecordingState.Ready;
    public AutoRecordPolicy Policy => autoRecord;

    public event EventHandler<RecordingState>? StateChanged;
    public event EventHandler<CompletedRecording>? RecordingCompleted;
    /// <summary>An automatic start failed; the argument is how long until the next try.</summary>
    public event EventHandler<(Exception Error, TimeSpan RetryIn)>? AutomaticStartFailed;

    public void SetSessionsRoot(string rootDirectory) => sessions.RootDirectory = rootDirectory;

    public async Task StartManualAsync(DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current is not null) return;
            await StartCoreAsync(now, SessionTrigger.Manual, null, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task ObserveAsync(AudioObservation observation, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var decision = autoRecord.Observe(observation);
            if (decision.Action == AutoRecordAction.Start && current is null)
            {
                try
                {
                    await StartCoreAsync(observation.At, SessionTrigger.MicrophoneActivity,
                        observation.MicrophoneOwner, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception exception) when (exception is not OperationCanceledException)
                {
                    var wait = autoRecord.StartFailed(observation.At);
                    AutomaticStartFailed?.Invoke(this, (exception, wait));
                }
            }
            else if (decision.Action == AutoRecordAction.Stop && current is not null)
            {
                await StopCoreAsync(observation.At, decision.StopReason!, cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// How long the once-a-second tick may go missing before the process is taken
    /// to have been frozen rather than merely busy.
    /// </summary>
    public static readonly TimeSpan FrozenGap = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Stops a recording that has reached the duration ceiling, or that the
    /// computer slept through. Checked on its own clock, apart from the call
    /// monitor, so the ceiling holds for a manual recording with auto-record off
    /// and even when the monitor keeps failing.
    /// </summary>
    /// <remarks>
    /// Modern Standby freezes a desktop app without the suspend broadcast that
    /// <c>PowerModeChanged</c> waits for: on the test laptop a recording went into
    /// standby after 59 s, woke eleven minutes later and was stopped by the ceiling
    /// as a 736-second meeting with a minute of audio. A tick that arrives long
    /// after the last one is that sleep, seen from the far side; the recording ends
    /// as <c>sleep</c> at the last moment it was known to be running.
    /// </remarks>
    public async Task EnforceCeilingAsync(DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var previous = lastTick;
            lastTick = now;
            if (current is null) return;
            // Only a gap inside this recording: one begun just after waking still
            // has the tick from before the sleep behind it.
            if (previous is { } alive && alive >= current.StartedAt && now - alive >= FrozenGap)
                await StopCoreAsync(alive, "sleep", cancellationToken).ConfigureAwait(false);
            else if (autoRecord.CeilingReached(now))
                await StopCoreAsync(now, "max-duration", cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task StopAsync(DateTimeOffset now, string reason, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (current is null) return;
            await StopCoreAsync(now, reason, cancellationToken).ConfigureAwait(false);
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
            else if (pausedAt is { } started)
            {
                pausedFor += DateTimeOffset.UtcNow - started;
                pausedAt = null;
            }
            Publish(State with { IsPaused = paused });
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task StartCoreAsync(
        DateTimeOffset now,
        SessionTrigger trigger,
        string? processFamily,
        CancellationToken cancellationToken)
    {
        var session = sessions.Start(now, null, trigger, processFamily);
        var captured = wholeSystemAudio?.Invoke() == true ? null : processFamily;
        try
        {
            await capture.StartAsync(session, captured, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            // Nothing was recorded, so there is nothing to keep: a folder left
            // behind would be queued, fail to transcribe, and say so.
            SessionStore.Discard(session);
            Publish(RecordingState.Ready);
            throw;
        }
        current = session;
        pausedAt = null;
        pausedFor = TimeSpan.Zero;
        autoRecord.RecordingStarted(now, trigger == SessionTrigger.Manual);
        Publish(new RecordingState(true, false, now, session.Directory, trigger, processFamily));
    }

    private async Task StopCoreAsync(DateTimeOffset now, string reason, CancellationToken cancellationToken)
    {
        var session = current!;
        CaptureStopResult result;
        try
        {
            result = await capture.StopAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // The tracks are on disk whatever the device did on the way out.
            result = new CaptureStopResult(0, 0);
        }
        if (pausedAt is { } pausedSince) pausedFor += DateTimeOffset.UtcNow - pausedSince;
        current = null;
        pausedAt = null;
        var paused = pausedFor;
        pausedFor = TimeSpan.Zero;
        autoRecord.RecordingStopped(reason);
        Publish(RecordingState.Ready);

        var manual = session.Trigger == SessionTrigger.Manual;
        if (AutoRecordPolicy.ShouldDiscard(manual, reason, now - session.StartedAt, autoRecord.Options))
        {
            SessionStore.Discard(session);
            RecordingCompleted?.Invoke(this, new CompletedRecording(session, reason, Discarded: true, Settled: true));
            return;
        }

        var settled = true;
        try
        {
            sessions.Complete(session, now, reason, result.MicrophoneOffsetMs, result.SystemOffsetMs,
                Math.Max(0, (int)paused.TotalSeconds));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            settled = false;
        }
        RecordingCompleted?.Invoke(this, new CompletedRecording(session, reason, Discarded: false, settled));
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
