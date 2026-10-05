using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
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
    private IWindowsAudioRecorder? microphone;
    private IWindowsAudioRecorder? system;
    private TrackWriter? microphoneTrack;
    private TrackWriter? systemTrack;
    private long startedAt100ns;
    private volatile bool paused;
    private volatile bool running;

    private readonly IWindowsAudioRecorderFactory recorderFactory;
    private readonly Lock diagnosticsGate = new();
    private string captureStage = "idle";
    public string DiagnosticsPath { get; }

    public WindowsAudioCapture(string? diagnosticsPath = null) : this(new WindowsAudioRecorderFactory(),
        diagnosticsPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Amanu Data", "audio-capture.log")) { }

    internal WindowsAudioCapture(IWindowsAudioRecorderFactory recorderFactory, string diagnosticsPath)
    {
        this.recorderFactory = recorderFactory;
        DiagnosticsPath = diagnosticsPath;
    }

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
        WriteDiagnostic($"start; system={(processFamily is null ? "all" : "process")}");
        try
        {
            try
            {
                await StartMicrophoneAsync(session, streamRouting: true, cancellationToken);
            }
            catch (COMException exception) when (exception.HResult == unchecked((int)0x88890001))
            {
                // Some default-device routing endpoints reject activation or startup with
                // AUDCLNT_E_NOT_INITIALIZED. Reopen the real default microphone once;
                // never reuse the partially initialized client or retry permission errors.
                WriteDiagnostic(captureStage + "; retry=fixed-default", exception, includeDevices: true);
                await DisposeMicrophoneAsync();
                cancellationToken.ThrowIfCancellationRequested();
                await StartMicrophoneAsync(session, streamRouting: false, cancellationToken);
            }

            captureStage = "system/create";
            system = await recorderFactory.CreateSystemAsync(processFamily);
            cancellationToken.ThrowIfCancellationRequested();
            systemTrack = new TrackWriter(session.SystemTrack, system.WaveFormat, startedAt100ns);
            system.DataAvailable += OnSystemData;
            system.RecordingStopped += (_, args) => OnTrackStopped("system", args);
            captureStage = "system/start";
            system.StartRecording();
            running = true;
            WriteDiagnostic($"ready; mic={microphone!.WaveFormat}; system={system.WaveFormat}");
            CaptureStarted?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception exception)
        {
            WriteDiagnostic(captureStage, exception, includeDevices: true);
            await DisposeCaptureAsync();
            throw;
        }
    }

    private async Task StartMicrophoneAsync(SessionHandle session, bool streamRouting, CancellationToken cancellationToken)
    {
        var mode = streamRouting ? "routed" : "fixed-default";
        captureStage = $"microphone/{mode}/create";
        microphone = await recorderFactory.CreateMicrophoneAsync(streamRouting);
        cancellationToken.ThrowIfCancellationRequested();
        microphoneTrack = new TrackWriter(session.MicrophoneTrack, microphone.WaveFormat, startedAt100ns);
        microphone.DataAvailable += OnMicrophoneData;
        microphone.RecordingStopped += (_, args) => OnTrackStopped("mic", args);
        captureStage = $"microphone/{mode}/start";
        microphone.StartRecording();
    }

    private void OnTrackStopped(string track, StoppedEventArgs args)
    {
        if (args.Exception is null) return;
        WriteDiagnostic($"{track}/stopped", args.Exception, includeDevices: true);
        TrackLost?.Invoke(this, track);
    }

    public Task<CaptureStopResult> StopAsync(CancellationToken cancellationToken) =>
        Task.Run(() => StopCoreAsync(cancellationToken), cancellationToken);

    private async Task<CaptureStopResult> StopCoreAsync(CancellationToken cancellationToken)
    {
        if (microphone is null || system is null) return new CaptureStopResult(0, 0);
        try
        {
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
                WriteDiagnostic("stop/events-timeout");
            }
            return new CaptureStopResult(microphoneTrack?.OffsetMs ?? 0, systemTrack?.OffsetMs ?? 0);
        }
        catch (Exception exception)
        {
            WriteDiagnostic("stop", exception, includeDevices: true);
            throw;
        }
        finally
        {
            await DisposeCaptureAsync();
        }
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

    private async Task DisposeCaptureAsync()
    {
        running = false;
        if (LiveStopping is { } stopLive)
        {
            try { await stopLive().ConfigureAwait(false); }
            catch (Exception exception) { WriteDiagnostic("cleanup/live", exception); }
        }
        await DisposeMicrophoneAsync();
        var recorder = system;
        var writer = systemTrack;
        system = null;
        systemTrack = null;
        await ReleaseTrackAsync("system", recorder, writer, OnSystemData);
        paused = false;
    }

    private async Task DisposeMicrophoneAsync()
    {
        var recorder = microphone;
        var writer = microphoneTrack;
        microphone = null;
        microphoneTrack = null;
        await ReleaseTrackAsync("microphone", recorder, writer, OnMicrophoneData);
    }

    private async Task ReleaseTrackAsync(string track, IWindowsAudioRecorder? recorder, TrackWriter? writer,
        CaptureDataAvailableHandler handler)
    {
        if (recorder is not null)
        {
            try
            {
                recorder.DataAvailable -= handler;
                await recorder.DisposeAsync();
            }
            catch (Exception exception) { WriteDiagnostic($"cleanup/{track}/device", exception); }
        }
        try { writer?.Dispose(); }
        catch (Exception exception) { WriteDiagnostic($"cleanup/{track}/file", exception); }
    }

    private void WriteDiagnostic(string stage, Exception? exception = null, bool includeDevices = false)
    {
        // Local-only metadata: never write audio, transcript text, credentials, or send logs.
        try
        {
            var details = $"{DateTimeOffset.Now:O} Amanu={typeof(WindowsAudioCapture).Assembly.GetName().Version} " +
                $"NAudio={typeof(WasapiRecorder).Assembly.GetName().Version} OS={Environment.OSVersion} " +
                $"arch={RuntimeInformation.OSArchitecture} stage={stage}{Environment.NewLine}";
            if (exception is not null) details += $"HRESULT=0x{exception.HResult:X8} {exception}{Environment.NewLine}";
            if (includeDevices)
            {
                try { details += recorderFactory.DescribeDevices() + Environment.NewLine; }
                catch (Exception reportError)
                {
                    details += $"device-report HRESULT=0x{reportError.HResult:X8} {reportError.Message}{Environment.NewLine}";
                }
            }
            lock (diagnosticsGate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(DiagnosticsPath))!);
                File.AppendAllText(DiagnosticsPath, details + Environment.NewLine);
            }
        }
        catch (Exception) { /* Diagnostics must never prevent recording or replace its error. */ }
    }

    public async ValueTask DisposeAsync()
    {
        // WasapiRecorder.DisposeAsync stops and joins its capture thread. Release
        // each track independently so one broken client cannot strand the other.
        if (microphone is not null || system is not null) await DisposeCaptureAsync();
    }
}

internal interface IWindowsAudioRecorder : IAsyncDisposable
{
    WaveFormat WaveFormat { get; }
    event CaptureDataAvailableHandler? DataAvailable;
    event EventHandler<StoppedEventArgs>? RecordingStopped;
    void StartRecording();
    void StopRecording();
}

internal interface IWindowsAudioRecorderFactory
{
    Task<IWindowsAudioRecorder> CreateMicrophoneAsync(bool streamRouting);
    Task<IWindowsAudioRecorder> CreateSystemAsync(string? processFamily);
    string DescribeDevices() => "";
}

internal sealed class WindowsAudioRecorder(WasapiRecorder recorder) : IWindowsAudioRecorder
{
    public WaveFormat WaveFormat => recorder.WaveFormat;
    public event CaptureDataAvailableHandler? DataAvailable { add => recorder.DataAvailable += value; remove => recorder.DataAvailable -= value; }
    public event EventHandler<StoppedEventArgs>? RecordingStopped { add => recorder.RecordingStopped += value; remove => recorder.RecordingStopped -= value; }
    public void StartRecording() => recorder.StartRecording();
    public void StopRecording() => recorder.StopRecording();
    public ValueTask DisposeAsync() => recorder.DisposeAsync();
}

internal sealed class WindowsAudioRecorderFactory : IWindowsAudioRecorderFactory
{
    public async Task<IWindowsAudioRecorder> CreateMicrophoneAsync(bool streamRouting) => new WindowsAudioRecorder(streamRouting
        ? await new WasapiRecorderBuilder().WithDefaultDeviceStreamRouting().BuildAsync()
        : new WasapiRecorderBuilder().Build());

    public async Task<IWindowsAudioRecorder> CreateSystemAsync(string? processFamily)
    {
        if (processFamily is null) return new WindowsAudioRecorder(new WasapiRecorderBuilder().WithLoopbackCapture().Build());
        var target = FindTargetProcess(processFamily)
            ?? throw new InvalidOperationException($"{processFamily} stopped before capture could start.");
        return new WindowsAudioRecorder(await new WasapiRecorderBuilder()
            .WithProcessLoopback((uint)target.Id, ProcessLoopbackMode.IncludeTargetProcessTree).BuildAsync());
    }

    public string DescribeDevices()
    {
        var lines = new List<string>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (var flow in new[] { DataFlow.Capture, DataFlow.Render })
        foreach (var role in new[] { Role.Console, Role.Communications })
        {
            try
            {
                using var device = enumerator.GetDefaultAudioEndpoint(flow, role);
                using var client = device.CreateAudioClient();
                lines.Add($"device={flow}/{role}; name={device.FriendlyName}; state={device.State}; format={client.MixFormat}");
            }
            catch (Exception exception)
            {
                lines.Add($"device={flow}/{role}; HRESULT=0x{exception.HResult:X8}; {exception.Message}");
            }
        }
        return string.Join(Environment.NewLine, lines);
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
