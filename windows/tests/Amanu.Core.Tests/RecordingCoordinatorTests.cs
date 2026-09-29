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
        coordinator.SessionCompleted += (_, session) =>
        {
            Assert.True(File.Exists(Path.Combine(session.Directory, "meta.json")));
            completed = session;
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
    public async Task Capture_start_failure_settles_marker_and_returns_to_ready()
    {
        using var root = new TemporaryDirectory();
        var capture = new InspectableCapture { StartException = new InvalidOperationException("no microphone") };
        var coordinator = Coordinator(root.Path, capture);

        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.StartManualAsync(Started));

        Assert.False(coordinator.State.IsRecording);
        var sessionDirectory = Assert.Single(Directory.GetDirectories(root.Path));
        Assert.False(File.Exists(Path.Combine(sessionDirectory, ".recording.json")));
        Assert.Contains("capture-error", File.ReadAllText(Path.Combine(sessionDirectory, "meta.json")));
    }

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
