using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading.Channels;
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

/// <summary>Two durable tracks. Device replacement never reopens or truncates a track file.</summary>
public sealed class WindowsAudioCapture : IAudioCapture, ILiveAudioSource
{
    private sealed class Track(bool microphone)
    {
        public bool Microphone { get; } = microphone;
        public string? Endpoint;
        public IAudioEndpointRecorder? Recorder;
        public TrackWriter? Writer;
        public string? Error;
        public readonly AudioPeakMeter Meter = new();
    }
    private readonly Track mic = new(true), system = new(false);
    private readonly Func<AudioDeviceSelection> selection;
    private readonly IAudioEndpointFactory factory;
    private readonly SemaphoreSlim gate = new(1, 1);
    private long startedAt100ns;
    private volatile bool paused;
    private volatile bool running;
    private string? processFamily;
    private string? sourceProcessFamily;
    private CancellationTokenSource? deviceWatch;
    private Task? watching;
    private Channel<string>? deviceEvents;
    private Task? writingEvents;

    public WindowsAudioCapture(Func<AudioDeviceSelection>? selection = null) : this(selection ?? (() => new("", "")), new WindowsAudioEndpointFactory()) { }
    internal WindowsAudioCapture(Func<AudioDeviceSelection> selection, IAudioEndpointFactory factory) { this.selection = selection; this.factory = factory; }
    public bool IsRunning => running;
    public long ElapsedMs => (TrackWriter.Now100ns() - startedAt100ns) / 10_000;
    public double MicrophoneLevel => paused ? 0 : mic.Meter.Level;
    public double SystemLevel => paused ? 0 : system.Meter.Level;
    public string? MicrophoneError => Volatile.Read(ref mic.Error);
    public string? SystemError => Volatile.Read(ref system.Error);
    public event LiveAudioHandler? LiveAudioAvailable;
    public event EventHandler? CaptureStarted;
    public event EventHandler<string>? TrackLost;
    public Func<Task>? LiveStopping { get; set; }

    public Task StartAsync(SessionHandle session, string? processFamily, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (running || mic.Recorder is not null || system.Recorder is not null) throw new InvalidOperationException("Capture is already running.");
            cancellationToken.ThrowIfCancellationRequested();
            startedAt100ns = TrackWriter.Now100ns(); this.processFamily = processFamily; sourceProcessFamily = session.ProcessFamily; paused = false;
            var choices = selection();
            try
            {
                await OpenAsync(mic, factory.Resolve(true, choices.Microphone)).ConfigureAwait(false);
                await OpenAsync(system, factory.Resolve(false, choices.Output)).ConfigureAwait(false);
                mic.Writer = new TrackWriter(session.MicrophoneTrack, mic.Recorder!.WaveFormat, startedAt100ns);
                system.Writer = new TrackWriter(session.SystemTrack, system.Recorder!.WaveFormat, startedAt100ns);
                mic.Recorder.StartRecording(); system.Recorder.StartRecording();
                running = true;
                deviceEvents = Channel.CreateUnbounded<string>(new() { SingleReader = true });
                var journal = deviceEvents;
                writingEvents = Task.Run(async () =>
                {
                    try
                    {
                        await foreach (var entry in journal.Reader.ReadAllAsync().ConfigureAwait(false))
                            await File.AppendAllTextAsync(Path.Combine(session.Directory, "audio-events.jsonl"), entry + Environment.NewLine).ConfigureAwait(false);
                    }
                    catch (IOException) { /* Audio capture does not depend on the diagnostic file. */ }
                    catch (UnauthorizedAccessException) { }
                });
                deviceWatch = new CancellationTokenSource();
                watching = WatchDevicesAsync(deviceWatch.Token);
                CaptureStarted?.Invoke(this, EventArgs.Empty);
            }
            catch { await ReleaseTracksAsync().ConfigureAwait(false); throw; }
        }
        finally { gate.Release(); }
    }, cancellationToken);

    private async Task OpenAsync(Track track, string endpoint)
    {
        var recorder = await factory.CreateAsync(track.Microphone, endpoint, track.Microphone ? null : processFamily).ConfigureAwait(false);
        track.Recorder = recorder; track.Endpoint = endpoint; track.Error = null; track.Meter.Clear();
        recorder.DataAvailable += (ReadOnlySpan<byte> data, AudioClientBufferFlags flags, long position, long at) =>
        {
            if (!ReferenceEquals(track.Recorder, recorder)) return;
            var silent = paused || flags.HasFlag(AudioClientBufferFlags.Silent);
            var invalidTime = flags.HasFlag(AudioClientBufferFlags.TimestampError);
            track.Meter.Observe(data, silent);
            track.Writer?.Write(data, silent, at, invalidTime);
            LiveAudioAvailable?.Invoke(track.Microphone, data, recorder.WaveFormat, silent,
                ((at > 0 && !invalidTime ? at : TrackWriter.Now100ns()) - startedAt100ns) / 10_000);
        };
        recorder.RecordingStopped += (_, args) =>
        {
            if (!ReferenceEquals(track.Recorder, recorder) || args.Exception is null) return;
            ReportLost(track, args.Exception);
        };
    }

    private void ReportLost(Track track, Exception exception)
    {
        var first = track.Error is null; track.Error = exception.Message; track.Meter.Clear();
        if (first) { RecordDeviceEvent(track, "unavailable"); TrackLost?.Invoke(this, track.Microphone ? "mic" : "system"); }
    }

    private void RecordDeviceEvent(Track track, string kind) => deviceEvents?.Writer.TryWrite(JsonSerializer.Serialize(new
    {
        at_ms = Math.Max(0, ElapsedMs), track = track.Microphone ? "mic" : "system", state = kind,
    }));

    public Task RefreshDevicesAsync() => Task.Run(async () =>
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!running) return;
            var choices = selection();
            foreach (var track in new[] { mic, system })
            {
                try
                {
                    var endpoint = factory.Resolve(track.Microphone, track.Microphone ? choices.Microphone : choices.Output);
                    if (endpoint == track.Endpoint && track.Error is null && track.Recorder is not null) continue;
                    var wasLost = track.Error is not null;
                    RecordDeviceEvent(track, "switching");
                    await ReleaseRecorderAsync(track).ConfigureAwait(false);
                    await OpenAsync(track, endpoint).ConfigureAwait(false);
                    // Every endpoint is opened at the same float format: a device
                    // change can keep writing to the existing WAV and live stream.
                    track.Recorder!.StartRecording();
                    RecordDeviceEvent(track, wasLost ? "resumed" : "changed");
                }
                catch (Exception exception)
                {
                    try { await ReleaseRecorderAsync(track).ConfigureAwait(false); }
                    catch (Exception) { /* Preserve the reason capture failed. */ }
                    ReportLost(track, exception);
                }
            }
        }
        finally { gate.Release(); }
    });

    public async Task SetSystemAudioScopeAsync(bool wholeSystem)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!running) return;
            var next = wholeSystem ? null : sourceProcessFamily;
            if (next != processFamily) { processFamily = next; system.Endpoint = null; }
        }
        finally { gate.Release(); }
        await RefreshDevicesAsync().ConfigureAwait(false);
    }

    private async Task WatchDevicesAsync(CancellationToken token)
    {
        try
        {
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false)) await RefreshDevicesAsync().ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception) { /* The explicit refresh reports per-track errors. */ }
    }

    public Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var watch = deviceWatch; var watchTask = watching;
        try
        {
            watch?.Cancel(); deviceWatch = null; watching = null;
            running = false;
            try { if (LiveStopping is { } stopLive) await stopLive().ConfigureAwait(false); }
            finally { await ReleaseTracksAsync().ConfigureAwait(false); }
            return new CaptureStopResult(0, 0);
        }
        finally
        {
            gate.Release();
            try { if (watchTask is not null) await watchTask.ConfigureAwait(false); }
            finally { watch?.Dispose(); }
        }
    }, cancellationToken);

    public Task SetPausedAsync(bool value, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested(); paused = value; mic.Meter.Clear(); system.Meter.Clear(); return Task.CompletedTask;
    }
    private static async Task ReleaseRecorderAsync(Track track)
    {
        var recorder = track.Recorder; track.Recorder = null; track.Meter.Clear();
        if (recorder is null) return;
        try { recorder.StopRecording(); }
        finally { await recorder.DisposeAsync().ConfigureAwait(false); }
    }
    private async Task ReleaseTracksAsync()
    {
        running = false;
        foreach (var track in new[] { mic, system })
        {
            try { await ReleaseRecorderAsync(track).ConfigureAwait(false); }
            catch (Exception exception) { ReportLost(track, exception); }
            try { track.Writer?.Dispose(); }
            catch (Exception exception) { ReportLost(track, exception); }
            finally { track.Writer = null; track.Endpoint = null; track.Meter.Clear(); }
        }
        deviceEvents?.Writer.TryComplete();
        if (writingEvents is not null) await writingEvents.ConfigureAwait(false);
        deviceEvents = null; writingEvents = null;
    }
    public async ValueTask DisposeAsync() => await StopAsync(default).ConfigureAwait(false);
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
        if (!packets.Writer.TryWrite(new Packet(copy, buffer.Length, silent, at)))
            System.Buffers.ArrayPool<byte>.Shared.Return(copy);
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
