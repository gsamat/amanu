using System.Diagnostics;
using System.IO;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Amanu.App;

/// <summary>
/// The microphone and the call, captured by WASAPI into two crash-tolerant WAV
/// files. The call is the call app's own process tree through application
/// loopback, or everything Windows plays when <c>system_audio</c> is <c>all</c>.
/// </summary>
public sealed class WindowsAudioCapture : IAudioCapture
{
    private WasapiRecorder? microphone;
    private WasapiRecorder? system;
    private TrackWriter? microphoneTrack;
    private TrackWriter? systemTrack;
    private long startedAt100ns;
    private CancellationTokenSource? liveLifetime;
    private Task? liveRotation;
    private string? liveDirectory;
    private int liveChunkIndex;
    private volatile bool paused;

    public bool LiveChunksEnabled { get; set; }
    public event EventHandler<LiveAudioChunk>? LiveChunkReady;

    /// <summary>A track stopped delivering audio because its device went away; the recording carries on with the other.</summary>
    public event EventHandler<string>? TrackLost;

    /// <remarks>
    /// Runs on the thread pool: a recorder built on the UI thread may hand its
    /// events back through the UI's dispatcher, and a stop that waits for them
    /// there — at sleep, at sign-out — would wait for itself.
    /// </remarks>
    public Task StartAsync(SessionHandle session, string? processFamily, CancellationToken cancellationToken) =>
        Task.Run(() => StartCoreAsync(session, processFamily, cancellationToken), cancellationToken);

    private async Task StartCoreAsync(SessionHandle session, string? processFamily, CancellationToken cancellationToken)
    {
        if (microphone is not null || system is not null) throw new InvalidOperationException("Capture is already running.");
        cancellationToken.ThrowIfCancellationRequested();
        startedAt100ns = TrackWriter.Now100ns();
        try
        {
            microphone = await new WasapiRecorderBuilder().WithDefaultDeviceStreamRouting().BuildAsync();
            if (processFamily is null)
            {
                system = new WasapiRecorderBuilder().WithLoopbackCapture().Build();
            }
            else
            {
                var target = FindTargetProcess(processFamily)
                    ?? throw new InvalidOperationException($"{processFamily} stopped before capture could start.");
                system = await new WasapiRecorderBuilder()
                    .WithProcessLoopback((uint)target.Id, ProcessLoopbackMode.IncludeTargetProcessTree)
                    .BuildAsync();
            }

            microphoneTrack = new TrackWriter(session.MicrophoneTrack, microphone.WaveFormat, startedAt100ns);
            systemTrack = new TrackWriter(session.SystemTrack, system.WaveFormat, startedAt100ns);
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
            microphone.RecordingStopped += (_, args) => { if (args.Exception is not null) TrackLost?.Invoke(this, "mic"); };
            system.RecordingStopped += (_, args) => { if (args.Exception is not null) TrackLost?.Invoke(this, "system"); };
            microphone.StartRecording();
            system.StartRecording();
        }
        catch
        {
            await DisposeCaptureAsync();
            throw;
        }
    }

    public Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken) =>
        Task.Run(() => StopCoreAsync(cancellationToken), cancellationToken);

    private async Task<CaptureStopResult> StopCoreAsync(CancellationToken cancellationToken)
    {
        if (microphone is null || system is null) return new CaptureStopResult(0, 0);

        var microphoneStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var systemStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        microphone.RecordingStopped += (_, _) => microphoneStopped.TrySetResult();
        system.RecordingStopped += (_, _) => systemStopped.TrySetResult();
        microphone.StopRecording();
        system.StopRecording();
        try
        {
            await Task.WhenAll(microphoneStopped.Task, systemStopped.Task).WaitAsync(TimeSpan.FromSeconds(8), cancellationToken);
        }
        catch (TimeoutException)
        {
            // A device that went away does not always say it stopped; what was
            // written is on disk either way.
        }

        var result = new CaptureStopResult(microphoneTrack?.OffsetMs ?? 0, systemTrack?.OffsetMs ?? 0);
        await DisposeCaptureAsync();
        return result;
    }

    public Task SetPausedAsync(bool value, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        paused = value;
        return Task.CompletedTask;
    }

    private void OnMicrophoneData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition) =>
        microphoneTrack?.Write(buffer, paused || flags.HasFlag(AudioClientBufferFlags.Silent), qpcPosition);

    private void OnSystemData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition) =>
        systemTrack?.Write(buffer, paused || flags.HasFlag(AudioClientBufferFlags.Silent), qpcPosition);

    private static Process? FindTargetProcess(string processFamily)
    {
        var name = Path.GetFileNameWithoutExtension(processFamily);
        return Process.GetProcessesByName(name).OrderBy(SafeStartTime).FirstOrDefault();
    }

    private static DateTime SafeStartTime(Process process)
    {
        try { return process.StartTime; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { return DateTime.MaxValue; }
    }

    private async Task DisposeCaptureAsync()
    {
        if (liveLifetime is not null)
        {
            await liveLifetime.CancelAsync();
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
        microphoneTrack?.Dispose();
        systemTrack?.Dispose();
        microphoneTrack = null;
        systemTrack = null;
        microphone = null;
        system = null;
        paused = false;
        liveDirectory = null;
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
        if (liveDirectory is null || microphoneTrack is null || systemTrack is null) return;
        var prefix = Path.Combine(liveDirectory, $"chunk-{liveChunkIndex:0000}");
        microphoneTrack.StartSide(prefix + "-mic.wav");
        systemTrack.StartSide(prefix + "-system.wav");
    }

    private LiveAudioChunk? CloseLiveWriters()
    {
        var mic = microphoneTrack?.EndSide();
        var call = systemTrack?.EndSide();
        if (mic is null || call is null) return null;
        var chunk = new LiveAudioChunk(mic, call, liveChunkIndex * 20_000L);
        liveChunkIndex++;
        return chunk;
    }

    public async ValueTask DisposeAsync()
    {
        if (microphone is not null || system is not null)
        {
            try
            {
                microphone?.StopRecording();
                system?.StopRecording();
            }
            finally
            {
                await DisposeCaptureAsync();
            }
        }
    }
}

public sealed record LiveAudioChunk(string MicrophonePath, string SystemPath, long OffsetMs);

/// <summary>
/// One track's WAV file, kept on the recording's timeline. Loopback capture sends
/// nothing at all while nothing plays, and a device change leaves a hole; either
/// way the missing time is written as silence, measured from the packet's own QPC
/// timestamp, so the two tracks stay aligned for the whole meeting. A single gap
/// is padded up to a cap, so a clock that jumps cannot write gigabytes of zeros.
/// </summary>
internal sealed class TrackWriter : IDisposable
{
    private static readonly long MaximumGap100ns = TimeSpan.FromMinutes(30).Ticks;
    private readonly Lock gate = new();
    private readonly WaveFileWriter writer;
    private readonly WaveFormat format;
    private readonly long origin100ns;
    private readonly byte[] zeros;
    private WaveFileWriter? side;
    private long? first100ns;
    private long framesWritten;
    private long lastFlush100ns;

    public TrackWriter(string path, WaveFormat format, long origin100ns)
    {
        this.format = format;
        this.origin100ns = origin100ns;
        writer = new WaveFileWriter(path, format);
        zeros = new byte[format.AverageBytesPerSecond / 10 / format.BlockAlign * format.BlockAlign];
    }

    /// <summary>How long after the recording started this track's first sound arrived.</summary>
    public int OffsetMs => first100ns is { } first ? (int)Math.Max(0, (first - origin100ns) / 10_000) : 0;

    public static long Now100ns() => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));

    public void Write(ReadOnlySpan<byte> buffer, bool silent, long qpc100ns)
    {
        lock (gate)
        {
            var at = qpc100ns > 0 ? qpc100ns : Now100ns();
            first100ns ??= at;
            var expected = (at - first100ns.Value) * format.SampleRate / 10_000_000;
            var missing = expected - framesWritten;
            // Anything under 50 ms is the ordinary jitter of packet timestamps.
            if (missing > format.SampleRate / 20)
            {
                var cap = MaximumGap100ns * format.SampleRate / 10_000_000;
                var gap = Math.Min(missing, cap);
                WriteSilence(gap * format.BlockAlign);
                framesWritten += gap;
            }
            if (silent) WriteSilence(buffer.Length);
            else
            {
                writer.Write(buffer);
                side?.Write(buffer);
            }
            framesWritten += buffer.Length / format.BlockAlign;
            // Flush rewrites the header's lengths, so a crash leaves a file every
            // reader can open with all but the last few seconds in it.
            if (at - lastFlush100ns > TimeSpan.FromSeconds(5).Ticks)
            {
                writer.Flush();
                lastFlush100ns = at;
            }
        }
    }

    private void WriteSilence(long bytes)
    {
        while (bytes > 0)
        {
            var piece = (int)Math.Min(bytes, zeros.Length);
            writer.Write(zeros, 0, piece);
            side?.Write(zeros, 0, piece);
            bytes -= piece;
        }
    }

    /// <summary>Starts a second file receiving the same audio — a live-transcript piece.</summary>
    public void StartSide(string path)
    {
        lock (gate) side = new WaveFileWriter(path, format);
    }

    public string? EndSide()
    {
        lock (gate)
        {
            if (side is null) return null;
            var path = side.Filename;
            side.Dispose();
            side = null;
            return path;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            side?.Dispose();
            side = null;
            writer.Dispose();
        }
    }
}
