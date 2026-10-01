using Amanu.Core.Recording;
using Amanu.Core.Sessions;

namespace Amanu.Core.Tests;

public sealed class RecordingCoordinatorTests
{
    private static readonly DateTimeOffset Started =
        new(2026, 9, 20, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task Manual_start_and_stop_leave_a_complete_session()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture();
        var coordinator = Coordinator(root.Path, capture);

        await coordinator.StartManualAsync(Started);

        Assert.True(coordinator.State.IsRecording);
        Assert.Equal(SessionTrigger.Manual, coordinator.State.Trigger);
        Assert.True(File.Exists(Path.Combine(coordinator.State.SessionDirectory!, ".recording.json")));
        Assert.Equal(coordinator.State.SessionDirectory, capture.StartedSession?.Directory);

        await coordinator.StopAsync(Started.AddMinutes(2), "manual");

        Assert.False(coordinator.State.IsRecording);
        Assert.True(capture.Stopped);
        Assert.True(File.Exists(Path.Combine(capture.StartedSession!.Directory, "meta.json")));
        Assert.False(File.Exists(Path.Combine(capture.StartedSession.Directory, ".recording.json")));
    }

    [Fact]
    public async Task Completed_session_is_published_only_after_meta_is_durable()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture();
        var coordinator = Coordinator(root.Path, capture);
        SessionHandle? completed = null;
        coordinator.RecordingCompleted += (_, recording) =>
        {
            Assert.True(File.Exists(Path.Combine(recording.Session.Directory, "meta.json")));
            Assert.True(recording.Settled);
            completed = recording.Session;
        };

        await coordinator.StartManualAsync(Started);
        await coordinator.StopAsync(Started.AddMinutes(1), "manual");

        Assert.Equal(capture.StartedSession, completed);
    }

    [Fact]
    public async Task Pause_and_resume_keep_the_same_session_and_publish_state()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture();
        var coordinator = Coordinator(root.Path, capture);
        await coordinator.StartManualAsync(Started);

        await coordinator.TogglePauseAsync();
        Assert.True(coordinator.State.IsPaused);
        Assert.True(capture.Paused);

        await coordinator.TogglePauseAsync();
        Assert.False(coordinator.State.IsPaused);
        Assert.False(capture.Paused);
    }

    [Fact]
    public async Task Automatic_observations_start_the_matching_process_family()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture();
        var coordinator = Coordinator(root.Path, capture);

        await coordinator.ObserveAsync(Observation(Started, "Zoom.exe"));
        await coordinator.ObserveAsync(Observation(Started.AddSeconds(12), "Zoom.exe"));

        Assert.True(coordinator.State.IsRecording);
        Assert.Equal(SessionTrigger.MicrophoneActivity, coordinator.State.Trigger);
        Assert.Equal("Zoom.exe", capture.ProcessFamily);
    }

    [Fact]
    public async Task Capture_start_failure_leaves_no_folder_behind()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture { StartException = new InvalidOperationException("no microphone") };
        var coordinator = Coordinator(root.Path, capture);

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StartManualAsync(Started));

        Assert.False(coordinator.State.IsRecording);
        Assert.Empty(Directory.GetDirectories(root.Path));
    }

    [Theory]
    [InlineData(2, true)]
    [InlineData(44, true)]
    [InlineData(45, false)]
    public async Task Default_three_second_start_still_discards_only_short_automatic_recordings(
        int recordedCallSeconds, bool discard)
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture();
        var defaults = new Amanu.Core.Configuration.AutoRecordSettings();
        var options = new AutoRecordOptions(true,
            TimeSpan.FromSeconds(defaults.StartDelaySeconds), TimeSpan.FromSeconds(defaults.StopDelaySeconds),
            TimeSpan.FromSeconds(defaults.MinimumDurationSeconds), TimeSpan.FromMinutes(defaults.SilenceStopMinutes),
            TimeSpan.FromMinutes(defaults.MaximumDurationMinutes));
        await using var coordinator = new RecordingCoordinator(
            new SessionStore(root.Path, processId: 99), new AutoRecordPolicy(options), capture);
        bool? discarded = null;
        coordinator.RecordingCompleted += (_, recording) => discarded = recording.Discarded;

        await coordinator.ObserveAsync(Observation(Started, "Zoom.exe"));
        await coordinator.ObserveAsync(Observation(Started.AddSeconds(2), "Zoom.exe"));
        Assert.False(coordinator.State.IsRecording);
        await coordinator.ObserveAsync(Observation(Started.AddSeconds(3), "Zoom.exe"));
        Assert.True(coordinator.State.IsRecording);

        var released = Started.AddSeconds(3 + recordedCallSeconds);
        await coordinator.ObserveAsync(Released(released));
        await coordinator.ObserveAsync(Released(released.AddSeconds(15)));

        Assert.False(coordinator.State.IsRecording);
        Assert.Equal(discard, discarded);
        Assert.Equal(!discard, Directory.Exists(capture.StartedSession!.Directory));
    }

    [Fact]
    public async Task A_failing_automatic_start_backs_off_instead_of_retrying_every_second()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture { StartException = new InvalidOperationException("device busy") };
        var coordinator = Coordinator(root.Path, capture);
        var failures = 0;
        coordinator.AutomaticStartFailed += (_, _) => failures++;

        for (var second = 0; second <= 40; second++)
            await coordinator.ObserveAsync(Observation(Started.AddSeconds(second), "Zoom.exe"));

        Assert.Equal(1, failures);
        Assert.Equal(AutoRecordPhase.BackingOff, coordinator.Policy.Phase);
        Assert.Empty(Directory.GetDirectories(root.Path));
    }

    [Fact]
    public async Task A_short_automatic_recording_is_discarded()
    {
        using var root = new TemporaryDirectory();
        var coordinator = Coordinator(root.Path, new InspectableCapture());
        CompletedRecording? completed = null;
        coordinator.RecordingCompleted += (_, recording) => completed = recording;

        await coordinator.ObserveAsync(Observation(Started, "Zoom.exe"));
        await coordinator.ObserveAsync(Observation(Started.AddSeconds(12), "Zoom.exe"));
        await coordinator.ObserveAsync(Released(Started.AddSeconds(20)));
        await coordinator.ObserveAsync(Released(Started.AddSeconds(35)));

        Assert.True(completed!.Discarded);
        Assert.Empty(Directory.GetDirectories(root.Path));
    }

    [Fact]
    public async Task The_ceiling_stops_a_manual_recording_without_the_call_monitor()
    {
        using var root = new TemporaryDirectory();
        var coordinator = Coordinator(root.Path, new InspectableCapture());
        await coordinator.StartManualAsync(Started);

        await coordinator.EnforceCeilingAsync(Started.AddHours(5));

        Assert.False(coordinator.State.IsRecording);
        Assert.Contains("max-duration", File.ReadAllText(Path.Combine(Directory.GetDirectories(root.Path)[0], "meta.json")));
    }

    [Fact]
    public async Task A_recording_slept_through_ends_as_sleep_where_the_ticks_stopped()
    {
        using var root = new TemporaryDirectory();
        var coordinator = Coordinator(root.Path, new InspectableCapture());
        await coordinator.StartManualAsync(Started);
        for (var second = 1; second <= 59; second++) await coordinator.EnforceCeilingAsync(Started.AddSeconds(second));

        // Modern Standby: no tick for eleven minutes, then one after waking.
        await coordinator.EnforceCeilingAsync(Started.AddSeconds(736));

        Assert.False(coordinator.State.IsRecording);
        var meta = File.ReadAllText(Path.Combine(Directory.GetDirectories(root.Path)[0], "meta.json"));
        Assert.Contains("\"sleep\"", meta);
        Assert.Contains("\"duration_seconds\": 59", meta);
    }

    [Fact]
    public async Task A_busy_second_or_a_start_after_waking_is_not_sleep()
    {
        using var root = new TemporaryDirectory();
        var coordinator = Coordinator(root.Path, new InspectableCapture());
        await coordinator.EnforceCeilingAsync(Started.AddMinutes(-30)); // the last tick before the lid closed
        await coordinator.StartManualAsync(Started);

        await coordinator.EnforceCeilingAsync(Started.AddSeconds(1));
        await coordinator.EnforceCeilingAsync(Started.AddSeconds(20));

        Assert.True(coordinator.State.IsRecording);
    }

    private static AudioObservation Released(DateTimeOffset at) => new(at, false, null, false, false);

    private static RecordingCoordinator Coordinator(string root, InspectableCapture capture)
    {
        var options = new AutoRecordOptions(
            Enabled: true,
            StartDelay: TimeSpan.FromSeconds(12),
            StopDelay: TimeSpan.FromSeconds(15),
            MinimumDuration: TimeSpan.FromSeconds(45),
            SilenceStop: TimeSpan.FromMinutes(10),
            MaximumDuration: TimeSpan.FromHours(5));
        return new RecordingCoordinator(
            new SessionStore(root, processId: 99), new AutoRecordPolicy(options), capture);
    }

    private static AudioObservation Observation(DateTimeOffset at, string process) => new(
        At: at,
        ConfiguredCallProcessOwnsMicrophone: true,
        MicrophoneOwner: process,
        MicrophoneHasSound: true,
        CallAudioHasSound: true);

    private sealed class InspectableCapture : IAudioCapture
    {
        public SessionHandle? StartedSession { get; private set; }
        public string? ProcessFamily { get; private set; }
        public bool Stopped { get; private set; }
        public Exception? StartException { get; init; }
        public bool Paused { get; private set; }

        public Task StartAsync(
            SessionHandle session,
            string? processFamily,
            CancellationToken cancellationToken)
        {
            StartedSession = session;
            ProcessFamily = processFamily;
            if (StartException is not null)
            {
                return Task.FromException(StartException);
            }
            return Task.CompletedTask;
        }

        public Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken)
        {
            Stopped = true;
            return Task.FromResult(new CaptureStopResult(0, 0));
        }

        public Task SetPausedAsync(bool paused, CancellationToken cancellationToken)
        {
            Paused = paused;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
