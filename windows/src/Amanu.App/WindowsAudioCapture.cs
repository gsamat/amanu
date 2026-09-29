using System.Diagnostics;
using System.IO;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Amanu.App;

public sealed class WindowsAudioCapture : IAudioCapture
{
    private readonly object writerGate = new();
    private WasapiRecorder? microphone;
    private WasapiRecorder? system;
    private WaveFileWriter? microphoneWriter;
    private WaveFileWriter? systemWriter;
    private DateTimeOffset? requestedAt;
    private DateTimeOffset? firstMicrophonePacketAt;
    private DateTimeOffset? firstSystemPacketAt;
    private WaveFileWriter? liveMicrophoneWriter;
    private WaveFileWriter? liveSystemWriter;
    private CancellationTokenSource? liveLifetime;
    private Task? liveRotation;
    private string? liveDirectory;
    private int liveChunkIndex;
    private volatile bool paused;
    private byte[] microphoneSilence = [];
    private byte[] systemSilence = [];

    public bool LiveChunksEnabled { get; set; }
    public event EventHandler<LiveAudioChunk>? LiveChunkReady;

    public async Task StartAsync(
        SessionHandle session,
        string? processFamily,
        CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(microphone is not null || system is not null, this);
        cancellationToken.ThrowIfCancellationRequested();
        requestedAt = DateTimeOffset.UtcNow;

        microphone = await new WasapiRecorderBuilder()
            .WithDefaultDeviceStreamRouting()
            .BuildAsync();

        if (processFamily is null)
        {
            system = new WasapiRecorderBuilder().WithLoopbackCapture().Build();
        }
        else
        {
            var target = FindTargetProcess(processFamily)
                ?? throw new InvalidOperationException($"{processFamily} stopped before capture could start.");
            system = await new WasapiRecorderBuilder()
                .WithProcessLoopback(
                    (uint)target.Id,
                    ProcessLoopbackMode.IncludeTargetProcessTree)
                .BuildAsync();
        }

        microphoneWriter = new WaveFileWriter(session.MicrophoneTrack, microphone.WaveFormat);
        systemWriter = new WaveFileWriter(session.SystemTrack, system.WaveFormat);
        if (LiveChunksEnabled)
        {
            liveDirectory = Path.Combine(session.Directory, ".live");
            Directory.CreateDirectory(liveDirectory);
            liveChunkIndex = 0;
            OpenLiveWriters();
            liveLifetime = new CancellationTokenSource();
            liveRotation = RotateLiveChunksAsync(liveLifetime.Token);
        }
        microphone.DataAvailable += OnMicrophoneData;
        system.DataAvailable += OnSystemData;

        try
        {
            microphone.StartRecording();
            system.StartRecording();
        }
        catch
        {
            await DisposeCaptureAsync();
            throw;
        }
    }

    public async Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken)
    {
        if (microphone is null || system is null)
        {
            return new CaptureStopResult(0, 0);
        }

        var microphoneStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var systemStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        microphone.RecordingStopped += (_, _) => microphoneStopped.TrySetResult();
        system.RecordingStopped += (_, _) => systemStopped.TrySetResult();
        microphone.StopRecording();
        system.StopRecording();

        await Task.WhenAll(microphoneStopped.Task, systemStopped.Task)
            .WaitAsync(TimeSpan.FromSeconds(8), cancellationToken);

        var result = new CaptureStopResult(
            Offset(firstMicrophonePacketAt),
            Offset(firstSystemPacketAt));
        await DisposeCaptureAsync();
        return result;
    }

    public Task SetPausedAsync(bool value, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        paused = value;
        return Task.CompletedTask;
    }

    private void OnMicrophoneData(
        ReadOnlySpan<byte> buffer,
        NAudio.CoreAudioApi.AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
    {
        _ = flags;
        _ = devicePosition;
        _ = qpcPosition;
        firstMicrophonePacketAt ??= DateTimeOffset.UtcNow;
        lock (writerGate)
        {
            var data = paused ? Silence(ref microphoneSilence, buffer.Length) : buffer;
            microphoneWriter?.Write(data);
            liveMicrophoneWriter?.Write(data);
        }
    }

    private void OnSystemData(
        ReadOnlySpan<byte> buffer,
        NAudio.CoreAudioApi.AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
    {
        _ = flags;
        _ = devicePosition;
        _ = qpcPosition;
        firstSystemPacketAt ??= DateTimeOffset.UtcNow;
        lock (writerGate)
        {
            var data = paused ? Silence(ref systemSilence, buffer.Length) : buffer;
            systemWriter?.Write(data);
            liveSystemWriter?.Write(data);
        }
    }

    private static Process? FindTargetProcess(string processFamily)
    {
        var name = Path.GetFileNameWithoutExtension(processFamily);
        return Process.GetProcessesByName(name)
            .OrderBy(SafeStartTime)
            .FirstOrDefault();
    }

    private static DateTime SafeStartTime(Process process)
    {
        try
        {
            return process.StartTime;
        }
        catch
        {
            return DateTime.MaxValue;
        }
    }

    private int Offset(DateTimeOffset? firstPacketAt) => requestedAt is { } started && firstPacketAt is { } first
        ? Math.Max(0, (int)(first - started).TotalMilliseconds)
        : 0;

    private async Task DisposeCaptureAsync()
    {
        if (liveLifetime is not null)
        {
            liveLifetime.Cancel();
            if (liveRotation is not null)
                try { await liveRotation.ConfigureAwait(false); } catch (OperationCanceledException) { }
            var final = CloseLiveWriters();
            if (final is not null) LiveChunkReady?.Invoke(this, final);
            liveLifetime.Dispose();
            liveLifetime = null;
            liveRotation = null;
        }
        if (microphone is not null)
        {
            microphone.DataAvailable -= OnMicrophoneData;
            await microphone.DisposeAsync();
        }
        if (system is not null)
        {
            system.DataAvailable -= OnSystemData;
            await system.DisposeAsync();
        }
        lock (writerGate)
        {
            microphoneWriter?.Dispose();
            systemWriter?.Dispose();
            microphoneWriter = null;
            systemWriter = null;
        }
        microphone = null;
        system = null;
        requestedAt = null;
        firstMicrophonePacketAt = null;
        firstSystemPacketAt = null;
        paused = false;
        liveDirectory = null;
    }

    private static ReadOnlySpan<byte> Silence(ref byte[] cache, int length)
    {
        if (cache.Length < length) cache = new byte[length];
        return cache.AsSpan(0, length);
    }

    private async Task RotateLiveChunksAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            var chunk = CloseLiveWriters();
            OpenLiveWriters();
            if (chunk is not null) LiveChunkReady?.Invoke(this, chunk);
        }
    }

    private void OpenLiveWriters()
    {
        if (liveDirectory is null || microphone is null || system is null) return;
        lock (writerGate)
        {
            var prefix = $"chunk-{liveChunkIndex:0000}";
            liveMicrophoneWriter = new WaveFileWriter(Path.Combine(liveDirectory, prefix + "-mic.wav"), microphone.WaveFormat);
            liveSystemWriter = new WaveFileWriter(Path.Combine(liveDirectory, prefix + "-system.wav"), system.WaveFormat);
        }
    }

    private LiveAudioChunk? CloseLiveWriters()
    {
        lock (writerGate)
        {
            if (liveMicrophoneWriter is null || liveSystemWriter is null) return null;
            var microphonePath = liveMicrophoneWriter.Filename;
            var systemPath = liveSystemWriter.Filename;
            liveMicrophoneWriter.Dispose();
            liveSystemWriter.Dispose();
            liveMicrophoneWriter = null;
            liveSystemWriter = null;
            var chunk = new LiveAudioChunk(microphonePath, systemPath, liveChunkIndex * 20_000L);
            liveChunkIndex++;
            return chunk;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (microphone is not null || system is not null)
        {
            try
            {
                if (microphone is not null)
                {
                    microphone.StopRecording();
                }
                if (system is not null)
                {
                    system.StopRecording();
                }
            }
            finally
            {
                await DisposeCaptureAsync();
            }
        }
    }
}

public sealed record LiveAudioChunk(string MicrophonePath, string SystemPath, long OffsetMs);
