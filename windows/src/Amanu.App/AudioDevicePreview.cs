using NAudio.CoreAudioApi;

namespace Amanu.App;

/// <summary>Ephemeral level checking. No session, files or transcription.</summary>
internal sealed class AudioDevicePreview(IAudioEndpointFactory factory) : IAsyncDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly AudioPeakMeter meter = new();
    private IAudioEndpointRecorder? recorder;
    public double Level => meter.Level;
    public bool IsRunning => recorder is not null;
    public string? Error { get; private set; }

    public Task StartAsync(bool microphone, string selection) => Task.Run(async () =>
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            await ReleaseAsync().ConfigureAwait(false);
            Error = null;
            recorder = await factory.CreateAsync(microphone, factory.Resolve(microphone, selection), null).ConfigureAwait(false);
            recorder.DataAvailable += OnData;
            recorder.RecordingStopped += OnStopped;
            recorder.StartRecording();
        }
        catch { await ReleaseAsync().ConfigureAwait(false); throw; }
        finally { gate.Release(); }
    });

    private void OnData(ReadOnlySpan<byte> data, AudioClientBufferFlags flags, long position, long at) => meter.Observe(data, flags.HasFlag(AudioClientBufferFlags.Silent));
    private void OnStopped(object? sender, NAudio.Wave.StoppedEventArgs args)
    {
        if (!ReferenceEquals(sender, recorder) || args.Exception is null) return;
        Error = args.Exception.Message;
        meter.Clear();
    }
    public Task StopAsync() => Task.Run(async () =>
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try { await ReleaseAsync().ConfigureAwait(false); }
        finally { gate.Release(); }
    });
    private async Task ReleaseAsync()
    {
        var current = recorder; recorder = null; meter.Clear();
        if (current is null) return;
        current.DataAvailable -= OnData;
        current.RecordingStopped -= OnStopped;
        try { current.StopRecording(); }
        finally { await current.DisposeAsync().ConfigureAwait(false); }
    }
    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);
}
