using System.Runtime.InteropServices;
using Amanu.App;
using Amanu.Core.Sessions;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Xunit;

namespace Amanu.Audio.Tests;

public sealed class AudioDeviceCaptureTests
{
    [Fact]
    public async Task Device_loss_and_replacement_leave_a_local_timeline_of_the_gap()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        var selected = new AudioDeviceSelection("old", "out");
        await using var capture = new WindowsAudioCapture(() => selected, factory);
        await capture.StartAsync(files.Session, null, default);
        factory.Recorders[0].Fail();
        selected = selected with { Microphone = "replacement" };
        await capture.RefreshDevicesAsync();
        await capture.StopAsync(default);
        var events = File.ReadAllText(Path.Combine(files.Directory, "audio-events.jsonl"));
        Assert.Contains("unavailable", events);
        Assert.Contains("resumed", events);
        Assert.Contains("at_ms", events);
    }

    [Fact]
    public async Task Switching_to_endpoint_scope_only_restarts_the_system_track()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        await using var capture = new WindowsAudioCapture(() => new("", ""), factory);
        await capture.StartAsync(files.Session with { ProcessFamily = "Zoom" }, "Zoom", default);
        var microphone = factory.Recorders[0]; var output = factory.Recorders[1];
        await capture.SetSystemAudioScopeAsync(true);
        Assert.False(microphone.Disposed);
        Assert.True(output.Disposed);
        Assert.Null(factory.Recorders[2].ProcessFamily);
    }

    [Fact]
    public async Task A_packet_from_a_replaced_recorder_is_not_written_to_the_meeting()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        var selected = new AudioDeviceSelection("old", "out");
        await using var capture = new WindowsAudioCapture(() => selected, factory);
        await capture.StartAsync(files.Session, null, default);
        var old = factory.Recorders[0]; selected = selected with { Microphone = "new" };
        await capture.RefreshDevicesAsync();
        old.Emit(.99f); factory.Recorders[2].Emit(.4f);
        await capture.StopAsync(default);
        using var reader = new WaveFileReader(files.Session.MicrophoneTrack);
        var data = new byte[(int)reader.Length]; reader.ReadExactly(data);
        Assert.DoesNotContain(.99f, MemoryMarshal.Cast<byte, float>(data).ToArray());
        Assert.Contains(.4f, MemoryMarshal.Cast<byte, float>(data).ToArray());
    }

    [Fact]
    public async Task A_level_expires_when_a_device_stops_delivering_packets()
    {
        var meter = new AudioPeakMeter();
        float[] samples = [-.4f, float.NaN, float.PositiveInfinity, .8f];
        meter.Observe(MemoryMarshal.AsBytes(samples.AsSpan()), false);
        Assert.Equal(.8, meter.Level, 4);
        await Task.Delay(750);
        Assert.Equal(0, meter.Level);
    }
    [Fact]
    public async Task Selected_endpoints_supply_the_recording_and_its_levels()
    {
        using var files = new SessionFiles();
        var factory = new TestEndpoints();
        await using var capture = new WindowsAudioCapture(() => new("headset-mic", "headset-out"), factory);
        await capture.StartAsync(files.Session, null, default);
        Assert.Equal("headset-mic", factory.Recorders[0].Id);
        Assert.Equal("headset-out", factory.Recorders[1].Id);
        factory.Recorders[0].Emit(.25f);
        factory.Recorders[1].Emit(.75f);
        Assert.Equal(.25, capture.MicrophoneLevel, 4);
        Assert.Equal(.75, capture.SystemLevel, 4);
        await capture.StopAsync(default);
        Assert.True(new FileInfo(files.Session.MicrophoneTrack).Length > 44);
        Assert.True(new FileInfo(files.Session.SystemTrack).Length > 44);
    }

    [Fact]
    public async Task Replacing_one_device_keeps_the_other_track_and_the_existing_WAV()
    {
        using var files = new SessionFiles();
        var factory = new TestEndpoints();
        var selected = new AudioDeviceSelection("first-mic", "out");
        await using var capture = new WindowsAudioCapture(() => selected, factory);
        await capture.StartAsync(files.Session, null, default);
        var microphone = factory.Recorders[0]; var output = factory.Recorders[1];
        microphone.Emit(.1f); output.Emit(.2f);
        selected = selected with { Microphone = "second-mic" };
        await capture.RefreshDevicesAsync();
        Assert.True(microphone.Disposed);
        Assert.False(output.Disposed);
        Assert.Equal("second-mic", factory.Recorders[2].Id);
        factory.Recorders[2].Emit(.9f); output.Emit(.3f);
        await capture.StopAsync(default);
        using var reader = new WaveFileReader(files.Session.MicrophoneTrack);
        var bytes = new byte[(int)reader.Length]; reader.ReadExactly(bytes);
        var samples = MemoryMarshal.Cast<byte, float>(bytes);
        Assert.Contains(.1f, samples.ToArray());
        Assert.Contains(.9f, samples.ToArray());
    }

    [Fact]
    public async Task Automatic_devices_follow_Windows_but_a_missing_fixed_device_does_not_fall_back()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        var selected = new AudioDeviceSelection("", "pinned-out");
        await using var capture = new WindowsAudioCapture(() => selected, factory);
        await capture.StartAsync(files.Session, null, default);
        factory.DefaultMicrophone = "new-default";
        await capture.RefreshDevicesAsync();
        Assert.Equal("new-default", factory.Recorders[2].Id);
        var count = factory.Recorders.Count;
        factory.Missing.Add("pinned-out");
        await capture.RefreshDevicesAsync();
        Assert.True(capture.IsRunning);
        Assert.NotNull(capture.SystemError);
        Assert.Equal(count, factory.Recorders.Count);
        Assert.Equal(0, capture.SystemLevel);
    }

    [Fact]
    public async Task A_stale_callback_from_a_replaced_device_cannot_report_loss_of_the_new_track()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        var selected = new AudioDeviceSelection("old", "out");
        await using var capture = new WindowsAudioCapture(() => selected, factory);
        await capture.StartAsync(files.Session, null, default);
        var old = factory.Recorders[0];
        selected = selected with { Microphone = "new" };
        await capture.RefreshDevicesAsync();
        old.Fail();
        Assert.Null(capture.MicrophoneError);
        Assert.True(capture.IsRunning);
    }

    [Fact]
    public async Task Pause_and_silence_zero_the_meter_without_becoming_a_device_failure()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        await using var capture = new WindowsAudioCapture(() => new("", ""), factory);
        await capture.StartAsync(files.Session, null, default);
        factory.Recorders[0].Emit(.8f);
        await capture.SetPausedAsync(true, default);
        Assert.Equal(0, capture.MicrophoneLevel);
        await capture.SetPausedAsync(false, default);
        factory.Recorders[0].Emit(.8f, AudioClientBufferFlags.Silent);
        Assert.Equal(0, capture.MicrophoneLevel);
        Assert.Null(capture.MicrophoneError);
    }

    [Fact]
    public async Task A_failed_system_start_releases_the_microphone_and_allows_a_new_start()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints { FailSystemStart = true };
        await using var capture = new WindowsAudioCapture(() => new("", ""), factory);
        await Assert.ThrowsAsync<InvalidOperationException>(() => capture.StartAsync(files.Session, null, default));
        Assert.All(factory.Recorders, recorder => Assert.True(recorder.Disposed));
        Assert.False(capture.IsRunning);
        factory.FailSystemStart = false;
        await capture.StartAsync(files.Session, null, default);
        Assert.True(capture.IsRunning);
    }

    [Fact]
    public async Task Process_capture_failure_is_not_silently_replaced_with_all_device_audio()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints { RejectProcess = true };
        await using var capture = new WindowsAudioCapture(() => new("", ""), factory);
        await Assert.ThrowsAsync<NotSupportedException>(() => capture.StartAsync(files.Session, "Zoom", default));
        Assert.False(capture.IsRunning);
        Assert.Single(factory.Recorders);
    }

    [Fact]
    public async Task Preview_creates_no_meeting_files_and_releases_its_recorder()
    {
        using var files = new SessionFiles(); var factory = new TestEndpoints();
        await using var preview = new AudioDevicePreview(factory);
        await preview.StartAsync(true, "headset");
        factory.Recorders[0].Emit(.6f);
        Assert.Equal(.6, preview.Level, 4);
        await preview.StopAsync();
        Assert.Equal(0, preview.Level);
        Assert.True(factory.Recorders[0].Disposed);
        Assert.Empty(Directory.GetFiles(files.Directory));
    }
}

internal sealed class SessionFiles : IDisposable
{
    public string Directory { get; } = Path.Combine(Path.GetTempPath(), "amanu-audio-tests-" + Guid.NewGuid().ToString("N"));
    public SessionHandle Session { get; }
    public SessionFiles()
    {
        System.IO.Directory.CreateDirectory(Directory);
        Session = new(Directory, Path.Combine(Directory, "mic.wav"), Path.Combine(Directory, "system.wav"), DateTimeOffset.Now, null, SessionTrigger.Manual, null);
    }
    public void Dispose() => System.IO.Directory.Delete(Directory, true);
}

internal sealed class TestEndpoints : IAudioEndpointFactory
{
    public string DefaultMicrophone { get; set; } = "default-mic";
    public HashSet<string> Missing { get; } = [];
    public List<TestRecorder> Recorders { get; } = [];
    public bool FailSystemStart { get; set; }
    public bool RejectProcess { get; set; }
    public string Resolve(bool microphone, string selection)
    {
        var id = selection == "" ? microphone ? DefaultMicrophone : "default-out" : selection;
        if (Missing.Contains(id)) throw new InvalidOperationException("Device disconnected");
        return id;
    }
    public Task<IAudioEndpointRecorder> CreateAsync(bool microphone, string endpoint, string? processFamily)
    {
        if (processFamily is not null && RejectProcess) throw new NotSupportedException("Process capture unavailable");
        var recorder = new TestRecorder(endpoint, microphone, !microphone && FailSystemStart) { ProcessFamily = processFamily };
        Recorders.Add(recorder);
        return Task.FromResult<IAudioEndpointRecorder>(recorder);
    }
}

internal sealed class TestRecorder(string id, bool microphone, bool failStart) : IAudioEndpointRecorder
{
    public string Id { get; } = id;
    public string? ProcessFamily { get; init; }
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(48000, microphone ? 1 : 2);
    public bool Disposed { get; private set; }
    public event CaptureDataAvailableHandler? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;
    public void StartRecording() { if (failStart) throw new InvalidOperationException("Start rejected"); }
    public void StopRecording() => RecordingStopped?.Invoke(this, new(null));
    public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    public void Fail() => RecordingStopped?.Invoke(this, new(new InvalidOperationException("Disconnected")));
    public void Emit(float sample, AudioClientBufferFlags flags = 0)
    {
        float[] samples = Enumerable.Repeat(sample, 480 * WaveFormat.Channels).ToArray();
        DataAvailable?.Invoke(MemoryMarshal.AsBytes(samples.AsSpan()), flags, 0, TrackWriter.Now100ns());
    }
}
