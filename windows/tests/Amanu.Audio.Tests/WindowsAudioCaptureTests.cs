using System.Runtime.InteropServices;
using Xunit;
using Amanu.App;
using Amanu.Core.Sessions;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Amanu.Core.Tests;

public sealed class WindowsAudioCaptureTests
{
    private const int NotInitialized = unchecked((int)0x88890001);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Uninitialized_routed_microphone_retries_with_a_fresh_default_device(bool failWhenStarting)
    {
        using var root = new TemporaryDirectory();
        var error = new COMException("The audio client has not been initialized.", NotInitialized);
        var routed = new Recorder { StartError = failWhenStarting ? error : null };
        var factory = new Factory { Routed = routed, RoutedError = failWhenStarting ? null : error };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));
        var session = Session(root.Path);

        await capture.StartAsync(session, null, CancellationToken.None);

        Assert.True(capture.IsRunning);
        Assert.True(factory.Fixed.Started);
        Assert.True(factory.System.Started);
        Assert.Equal(new[] { true, false }, factory.MicrophoneAttempts);
        if (failWhenStarting) Assert.True(routed.Disposed);
        await capture.StopAsync(CancellationToken.None);
        using var microphone = new WaveFileReader(session.MicrophoneTrack);
        Assert.True(microphone.Length > 0);
        Assert.Contains("0x88890001", File.ReadAllText(capture.DiagnosticsPath));
    }

    [Fact]
    public async Task Microphone_access_denied_does_not_retry_and_retains_the_failure_diagnostics()
    {
        using var root = new TemporaryDirectory();
        var error = new COMException("Microphone access denied", unchecked((int)0x80070005));
        var factory = new Factory { RoutedError = error };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));

        var thrown = await Assert.ThrowsAsync<COMException>(() => capture.StartAsync(Session(root.Path), null, CancellationToken.None));

        Assert.Same(error, thrown);
        Assert.Equal(new[] { true }, factory.MicrophoneAttempts);
        Assert.False(capture.IsRunning);
        Assert.True(File.Exists(capture.DiagnosticsPath));
        var log = File.ReadAllText(capture.DiagnosticsPath);
        Assert.Contains("0x80070005", log);
        Assert.Contains("Microphone access denied", log);
        Assert.Contains("microphone", log);
    }

    [Fact]
    public async Task Cleanup_failure_does_not_replace_the_start_error_or_prevent_a_later_recording()
    {
        using var root = new TemporaryDirectory();
        var original = new COMException("System device unavailable", unchecked((int)0x88890004));
        var broken = new Recorder { DisposeError = new IOException("cleanup failed") };
        var factory = new Factory { Routed = broken, SystemError = original };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));
        var session = Session(root.Path);

        var thrown = await Assert.ThrowsAsync<COMException>(() => capture.StartAsync(session, null, CancellationToken.None));

        Assert.Same(original, thrown);
        Assert.True(broken.Disposed);
        Assert.False(capture.IsRunning);
        factory.Routed = new Recorder();
        factory.SystemError = null;
        await capture.StartAsync(session, null, CancellationToken.None);
        Assert.True(capture.IsRunning);
        await capture.StopAsync(CancellationToken.None);
        var log = File.ReadAllText(capture.DiagnosticsPath);
        Assert.Contains("System device unavailable", log);
        Assert.Contains("cleanup failed", log);
    }

    [Fact]
    public async Task Working_stream_routing_keeps_both_tracks_and_does_not_use_the_fallback()
    {
        using var root = new TemporaryDirectory();
        var factory = new Factory();
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));
        var session = Session(root.Path);
        var started = 0;
        capture.CaptureStarted += (_, _) => started++;

        await capture.StartAsync(session, "Zoom", CancellationToken.None);
        await capture.StopAsync(CancellationToken.None);

        Assert.Equal(1, started);
        Assert.Equal("Zoom", factory.ProcessFamily);
        Assert.Equal(new[] { true }, factory.MicrophoneAttempts);
        Assert.True(factory.Routed.Disposed);
        Assert.True(factory.System.Disposed);
        Assert.False(capture.IsRunning);
        using var mic = new WaveFileReader(session.MicrophoneTrack);
        using var system = new WaveFileReader(session.SystemTrack);
        Assert.True(mic.Length > 0);
        Assert.True(system.Length > 0);
    }

    [Fact]
    public async Task A_failed_fallback_records_both_errors_and_releases_both_devices()
    {
        using var root = new TemporaryDirectory();
        var first = new COMException("routing not initialized", NotInitialized);
        var second = new COMException("default microphone unavailable", unchecked((int)0x88890004));
        var factory = new Factory { RoutedError = first, Fixed = new Recorder { StartError = second } };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));

        var thrown = await Assert.ThrowsAsync<COMException>(() => capture.StartAsync(Session(root.Path), null, CancellationToken.None));

        Assert.Same(second, thrown);
        Assert.True(factory.Fixed.Disposed);
        Assert.False(capture.IsRunning);
        Assert.True(File.Exists(capture.DiagnosticsPath));
        var log = File.ReadAllText(capture.DiagnosticsPath);
        Assert.Contains("routing not initialized", log);
        Assert.Contains("default microphone unavailable", log);
        Assert.Contains("0x88890004", log);
    }

    [Fact]
    public async Task System_initialization_failure_does_not_change_the_microphone_or_silently_drop_system_audio()
    {
        using var root = new TemporaryDirectory();
        var error = new COMException("system not initialized", NotInitialized);
        var factory = new Factory { System = new Recorder { StartError = error } };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));

        var thrown = await Assert.ThrowsAsync<COMException>(() => capture.StartAsync(Session(root.Path), null, CancellationToken.None));

        Assert.Same(error, thrown);
        Assert.Equal(new[] { true }, factory.MicrophoneAttempts);
        Assert.True(factory.Routed.Disposed);
        Assert.True(factory.System.Disposed);
        Assert.False(capture.IsRunning);
        Assert.True(File.Exists(capture.DiagnosticsPath));
        Assert.Contains("system", File.ReadAllText(capture.DiagnosticsPath));
    }

    [Fact]
    public async Task Cancelling_during_device_creation_releases_the_device_without_starting_audio()
    {
        using var root = new TemporaryDirectory();
        using var cancellation = new CancellationTokenSource();
        var factory = new Factory { AfterMicrophoneCreated = cancellation.Cancel };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => capture.StartAsync(Session(root.Path), null, cancellation.Token));

        Assert.False(factory.Routed.Started);
        Assert.True(factory.Routed.Disposed);
        Assert.False(factory.System.Started);
        Assert.False(capture.IsRunning);
    }

    [Fact]
    public async Task Live_shutdown_failure_still_releases_the_audio_files_and_devices()
    {
        using var root = new TemporaryDirectory();
        var factory = new Factory();
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));
        var session = Session(root.Path);
        await capture.StartAsync(session, null, CancellationToken.None);
        capture.LiveStopping = () => throw new InvalidOperationException("live shutdown failed");

        await capture.StopAsync(CancellationToken.None);

        Assert.True(factory.Routed.Disposed);
        Assert.True(factory.System.Disposed);
        Assert.False(capture.IsRunning);
        using var writable = File.Open(session.MicrophoneTrack, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Assert.Contains("live shutdown failed", File.ReadAllText(capture.DiagnosticsPath));
    }

    [Fact]
    public async Task Failing_to_inspect_devices_still_saves_the_original_start_error()
    {
        using var root = new TemporaryDirectory();
        var original = new COMException("original audio error", unchecked((int)0x80070005));
        var factory = new Factory { RoutedError = original, DeviceReportError = new COMException("device report failed") };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));

        var thrown = await Assert.ThrowsAsync<COMException>(() => capture.StartAsync(Session(root.Path), null, CancellationToken.None));

        Assert.Same(original, thrown);
        Assert.Contains("original audio error", File.ReadAllText(capture.DiagnosticsPath));
    }

    [Fact]
    public async Task An_unwritable_diagnostic_file_does_not_prevent_recording()
    {
        using var root = new TemporaryDirectory();
        var blocker = Path.Combine(root.Path, "file-not-directory");
        File.WriteAllText(blocker, "occupied");
        var factory = new Factory();
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(blocker, "audio-capture.log"));

        await capture.StartAsync(Session(root.Path), null, CancellationToken.None);
        Assert.True(capture.IsRunning);
        await capture.StopAsync(CancellationToken.None);
        Assert.True(factory.System.Disposed);
    }

    [Fact]
    public async Task A_stop_error_still_releases_every_device_and_finalizes_the_audio_files()
    {
        using var root = new TemporaryDirectory();
        var factory = new Factory { Routed = new Recorder { StopError = new COMException("stop failed") } };
        await using var capture = new WindowsAudioCapture(factory, Path.Combine(root.Path, "audio-capture.log"));
        var session = Session(root.Path);
        await capture.StartAsync(session, null, CancellationToken.None);

        await Assert.ThrowsAsync<COMException>(() => capture.StopAsync(CancellationToken.None));

        Assert.True(factory.Routed.Disposed);
        Assert.True(factory.System.Disposed);
        Assert.False(capture.IsRunning);
        using var writable = File.Open(session.MicrophoneTrack, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    }

    private static SessionHandle Session(string root) => new(root, Path.Combine(root, "mic.wav"),
        Path.Combine(root, "system.wav"), DateTimeOffset.UtcNow, null, SessionTrigger.Manual, null);

    private sealed class Factory : IWindowsAudioRecorderFactory
    {
        public Recorder Routed { get; set; } = new();
        public Recorder Fixed { get; init; } = new();
        public Recorder System { get; init; } = new();
        public Exception? RoutedError { get; init; }
        public Exception? SystemError { get; set; }
        public Exception? DeviceReportError { get; init; }
        public Action? AfterMicrophoneCreated { get; init; }
        public string? ProcessFamily { get; private set; }
        public List<bool> MicrophoneAttempts { get; } = [];

        public string DescribeDevices()
        {
            if (DeviceReportError is not null) throw DeviceReportError;
            return "test microphone and speakers";
        }

        public Task<IWindowsAudioRecorder> CreateMicrophoneAsync(bool streamRouting)
        {
            MicrophoneAttempts.Add(streamRouting);
            if (streamRouting && RoutedError is not null) throw RoutedError;
            AfterMicrophoneCreated?.Invoke();
            return Task.FromResult<IWindowsAudioRecorder>(streamRouting ? Routed : Fixed);
        }

        public Task<IWindowsAudioRecorder> CreateSystemAsync(string? processFamily)
        {
            ProcessFamily = processFamily;
            if (SystemError is not null) throw SystemError;
            return Task.FromResult<IWindowsAudioRecorder>(System);
        }
    }

    private sealed class Recorder : IWindowsAudioRecorder
    {
        public WaveFormat WaveFormat { get; } = new(48000, 16, 1);
        public Exception? StartError { get; init; }
        public Exception? StopError { get; init; }
        public Exception? DisposeError { get; init; }
        public bool Started { get; private set; }
        public bool Disposed { get; private set; }
        public event CaptureDataAvailableHandler? DataAvailable;
        public event EventHandler<StoppedEventArgs>? RecordingStopped;

        public void StartRecording()
        {
            if (StartError is not null) throw StartError;
            Started = true;
            DataAvailable?.Invoke(new byte[960], AudioClientBufferFlags.None, 0, 0);
        }

        public void StopRecording()
        {
            if (StopError is not null) throw StopError;
            RecordingStopped?.Invoke(this, new StoppedEventArgs());
        }

        public ValueTask DisposeAsync()
        {
            if (Disposed) return ValueTask.CompletedTask;
            Disposed = true;
            if (DisposeError is not null) throw DisposeError;
            return ValueTask.CompletedTask;
        }
    }
}
