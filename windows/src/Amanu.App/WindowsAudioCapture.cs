using System.Diagnostics;
using System.IO;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Amanu.App;

public delegate void LiveAudioHandler(bool microphone, ReadOnlySpan<byte> data, WaveFormat format, bool silent, long offsetMs);

public interface ILiveAudioSource
{
    bool IsRunning { get; }
    long ElapsedMs { get; }
    event LiveAudioHandler? LiveAudioAvailable;
    event EventHandler? CaptureStarted;
    Func<Task>? LiveStopping { get; set; }
}

/// <summary>
/// The microphone and the call, captured by WASAPI into two crash-tolerant WAV
/// files. Live recognition receives packets independently of the durable files.
/// </summary>
public sealed class WindowsAudioCapture : IAudioCapture, ILiveAudioSource
{
    private WasapiRecorder? microphone;
    private WasapiRecorder? system;
    private TrackWriter? microphoneTrack;
    private TrackWriter? systemTrack;
    private long startedAt100ns;
    private volatile bool paused;
    private volatile bool running;

    public bool IsRunning => running;
    public long ElapsedMs => (TrackWriter.Now100ns() - startedAt100ns) / 10_000;
    public event LiveAudioHandler? LiveAudioAvailable;
    public event EventHandler? CaptureStarted;
    public Func<Task>? LiveStopping { get; set; }

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
            microphone.DataAvailable += OnMicrophoneData;
            system.DataAvailable += OnSystemData;
            microphone.RecordingStopped += (_, args) => { if (args.Exception is not null) TrackLost?.Invoke(this, "mic"); };
            system.RecordingStopped += (_, args) => { if (args.Exception is not null) TrackLost?.Invoke(this, "system"); };
            microphone.StartRecording();
            system.StartRecording();
            running = true;
            CaptureStarted?.Invoke(this, EventArgs.Empty);
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

    private void OnMicrophoneData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition)
    {
        var silent = paused || flags.HasFlag(AudioClientBufferFlags.Silent);
        var invalidTime = flags.HasFlag(AudioClientBufferFlags.TimestampError);
        microphoneTrack?.Write(buffer, silent, qpcPosition, invalidTime);
        if (microphone is not null) LiveAudioAvailable?.Invoke(true, buffer, microphone.WaveFormat, silent,
            ((qpcPosition > 0 && !invalidTime ? qpcPosition : TrackWriter.Now100ns()) - startedAt100ns) / 10_000);
    }

    private void OnSystemData(ReadOnlySpan<byte> buffer, AudioClientBufferFlags flags, long devicePosition, long qpcPosition)
    {
        var silent = paused || flags.HasFlag(AudioClientBufferFlags.Silent);
        var invalidTime = flags.HasFlag(AudioClientBufferFlags.TimestampError);
        systemTrack?.Write(buffer, silent, qpcPosition, invalidTime);
        if (system is not null) LiveAudioAvailable?.Invoke(false, buffer, system.WaveFormat, silent,
            ((qpcPosition > 0 && !invalidTime ? qpcPosition : TrackWriter.Now100ns()) - startedAt100ns) / 10_000);
    }

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
        running = false;
        if (LiveStopping is { } stopLive) await stopLive().ConfigureAwait(false);
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

/// <summary>
/// One track's WAV file, kept on the recording's timeline. Loopback capture sends
/// nothing at all while nothing plays, and a device change leaves a hole; either
/// way the missing time is written as silence, measured from the packet's own QPC
/// timestamp — from the moment the recording started, so both files begin at the
/// same instant and stay aligned even when a crash loses everything held in
/// memory. A single gap is padded up to a cap, so a clock that jumps cannot write
/// gigabytes of zeros.
/// </summary>
/// <remarks>
/// The WASAPI callback only copies the packet into a queue. Writing — the gaps
/// above all, which can be minutes of zeros — happens on a thread of its own, so
/// the capture thread never stalls and the audio after a gap is not lost to a
/// buffer overrun.
/// </remarks>
internal sealed class TrackWriter : IDisposable
{
    private static readonly long MaximumGap100ns = TimeSpan.FromMinutes(30).Ticks;
    private readonly Lock gate = new();
    private readonly WaveFileWriter writer;
    private readonly WaveFormat format;
    private readonly long origin100ns;
    private readonly byte[] zeros;
    private readonly System.Threading.Channels.Channel<Packet> packets =
        System.Threading.Channels.Channel.CreateUnbounded<Packet>(new() { SingleReader = true, SingleWriter = true });
    private readonly Task drain;
    private long framesWritten;
    private long lastFlush100ns;

    private readonly record struct Packet(byte[] Data, int Length, bool Silent, long At100ns);

    public TrackWriter(string path, WaveFormat format, long origin100ns)
    {
        this.format = format;
        this.origin100ns = origin100ns;
        writer = new WaveFileWriter(path, format);
        zeros = new byte[Math.Max(format.BlockAlign, format.AverageBytesPerSecond / 10 / format.BlockAlign * format.BlockAlign)];
        drain = Task.Run(DrainAsync);
    }

    /// <summary>Always zero: every track starts at the recording's start, padded with silence until its first sound.</summary>
    public int OffsetMs => 0;

    public static long Now100ns() => (long)(Stopwatch.GetTimestamp() * (10_000_000.0 / Stopwatch.Frequency));

    /// <summary>Called on the capture thread: copies and queues, nothing more.</summary>
    public void Write(ReadOnlySpan<byte> buffer, bool silent, long qpc100ns, bool timestampError)
    {
        var copy = System.Buffers.ArrayPool<byte>.Shared.Rent(Math.Max(1, buffer.Length));
        buffer.CopyTo(copy);
        var at = qpc100ns > 0 && !timestampError ? qpc100ns : Now100ns();
        packets.Writer.TryWrite(new Packet(copy, buffer.Length, silent, at));
    }

    private async Task DrainAsync()
    {
        await foreach (var packet in packets.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                lock (gate) WritePacket(packet);
            }
            catch (Exception exception) when (exception is IOException or ObjectDisposedException)
            {
                // A full disk or a closed file: the rest of this track is lost, and
                // the recording carries on with what was written.
            }
            finally
            {
                System.Buffers.ArrayPool<byte>.Shared.Return(packet.Data);
            }
        }
    }

    private void WritePacket(Packet packet)
    {
        var expected = (packet.At100ns - origin100ns) * format.SampleRate / 10_000_000;
        var missing = expected - framesWritten;
        // Anything under 50 ms is the ordinary jitter of packet timestamps.
        if (missing > format.SampleRate / 20)
        {
            var gap = Math.Min(missing, MaximumGap100ns * format.SampleRate / 10_000_000);
            WriteSilence(gap * format.BlockAlign);
            framesWritten += gap;
        }
        if (packet.Silent) WriteSilence(packet.Length);
        else
        {
            writer.Write(packet.Data, 0, packet.Length);
        }
        framesWritten += packet.Length / format.BlockAlign;
        // Flush rewrites the header's lengths, so a crash leaves a file every
        // reader can open with all but the last few seconds in it.
        if (packet.At100ns - lastFlush100ns > TimeSpan.FromSeconds(5).Ticks)
        {
            writer.Flush();
            lastFlush100ns = packet.At100ns;
        }
    }

    private void WriteSilence(long bytes)
    {
        while (bytes > 0)
        {
            var piece = (int)Math.Min(bytes, zeros.Length);
            writer.Write(zeros, 0, piece);
            bytes -= piece;
        }
    }

    public void Dispose()
    {
        packets.Writer.TryComplete();
        drain.Wait(TimeSpan.FromSeconds(30));
        lock (gate)
        {
            writer.Dispose();
        }
    }
}
