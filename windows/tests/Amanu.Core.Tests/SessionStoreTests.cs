using System.Text.Json;
using Amanu.Core.Sessions;

namespace Amanu.Core.Tests;

public sealed class SessionStoreTests
{
    private static readonly DateTimeOffset Started =
        new(2026, 9, 20, 12, 34, 0, TimeSpan.Zero);

    [Fact]
    public void Starting_a_session_creates_a_sortable_folder_and_crash_marker()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path, processId: 42);

        var session = store.Start(Started, "Weekly: sync?", SessionTrigger.MicrophoneActivity,
            processFamily: "Zoom.exe");

        Assert.Equal("2026.09.20-1234 Weekly sync", System.IO.Path.GetFileName(session.Directory));
        Assert.Equal("mic.wav", System.IO.Path.GetFileName(session.MicrophoneTrack));
        Assert.Equal("system.wav", System.IO.Path.GetFileName(session.SystemTrack));
        Assert.True(File.Exists(System.IO.Path.Combine(session.Directory, ".recording.json")));

        using var marker = JsonDocument.Parse(File.ReadAllText(
            System.IO.Path.Combine(session.Directory, ".recording.json")));
        Assert.Equal(42, marker.RootElement.GetProperty("pid").GetInt32());
        Assert.Equal("mic-activity", marker.RootElement.GetProperty("trigger").GetString());
        Assert.Equal("Zoom.exe", marker.RootElement.GetProperty("process_family").GetString());
    }

    [Fact]
    public void Completing_a_session_publishes_meta_before_removing_the_crash_marker()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path, processId: 42);
        var session = store.Start(Started, null, SessionTrigger.Manual, processFamily: null);

        store.Complete(session, Started.AddMinutes(4), "manual", micOffsetMs: 0, systemOffsetMs: 83);

        Assert.False(File.Exists(System.IO.Path.Combine(session.Directory, ".recording.json")));
        using var meta = JsonDocument.Parse(File.ReadAllText(
            System.IO.Path.Combine(session.Directory, "meta.json")));
        Assert.Equal(240, meta.RootElement.GetProperty("duration_seconds").GetInt32());
        Assert.Equal("mic.wav", meta.RootElement.GetProperty("files").GetProperty("mic").GetString());
        Assert.Equal(83, meta.RootElement.GetProperty("start_offset_ms").GetProperty("system").GetInt32());
        Assert.Equal("windows", meta.RootElement.GetProperty("platform").GetString());
    }

    [Fact]
    public void An_orphaned_marker_is_adopted_as_an_interrupted_session()
    {
        using var root = new TemporaryDirectory();
        var store = new SessionStore(root.Path, processId: 42);
        var session = store.Start(Started, "Call", SessionTrigger.MicrophoneActivity, "Zoom.exe");
        File.WriteAllBytes(session.MicrophoneTrack, [1, 2, 3]);

        var recovered = store.RecoverInterrupted(
            now: Started.AddMinutes(2), processIsAlive: _ => false);

        Assert.Single(recovered);
        Assert.Equal(session.Directory, recovered[0]);
        Assert.True(File.Exists(System.IO.Path.Combine(session.Directory, "meta.json")));
        Assert.False(File.Exists(System.IO.Path.Combine(session.Directory, ".recording.json")));
        using var meta = JsonDocument.Parse(File.ReadAllText(
            System.IO.Path.Combine(session.Directory, "meta.json")));
        Assert.Equal("interrupted", meta.RootElement.GetProperty("stop_reason").GetString());
    }
}
