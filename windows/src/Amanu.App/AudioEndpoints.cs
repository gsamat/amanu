using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Amanu.App;

public sealed record AudioDeviceSelection(string Microphone, string Output);
public sealed record AudioEndpointChoice(string Id, string Name);

internal interface IAudioEndpointRecorder : IAsyncDisposable
{
    WaveFormat WaveFormat { get; }
    event CaptureDataAvailableHandler? DataAvailable;
    event EventHandler<StoppedEventArgs>? RecordingStopped;
    void StartRecording();
    void StopRecording();
}

internal interface IAudioEndpointFactory
{
    string Resolve(bool microphone, string selection);
    Task<IAudioEndpointRecorder> CreateAsync(bool microphone, string endpoint, string? processFamily);
}

internal sealed class WasapiEndpointRecorder(WasapiRecorder recorder, MMDevice? device) : IAudioEndpointRecorder
{
    public WaveFormat WaveFormat => recorder.WaveFormat;
    public event CaptureDataAvailableHandler? DataAvailable { add => recorder.DataAvailable += value; remove => recorder.DataAvailable -= value; }
    public event EventHandler<StoppedEventArgs>? RecordingStopped { add => recorder.RecordingStopped += value; remove => recorder.RecordingStopped -= value; }
    public void StartRecording() => recorder.StartRecording();
    public void StopRecording() => recorder.StopRecording();
    public async ValueTask DisposeAsync() { try { await recorder.DisposeAsync().ConfigureAwait(false); } finally { device?.Dispose(); } }
}

internal sealed class WindowsAudioEndpointFactory : IAudioEndpointFactory
{
    public string Resolve(bool microphone, string selection)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var device = string.IsNullOrEmpty(selection)
            ? enumerator.GetDefaultAudioEndpoint(microphone ? DataFlow.Capture : DataFlow.Render, Role.Console)
            : enumerator.GetDevice(selection);
        if (device.State != DeviceState.Active || device.DataFlow != (microphone ? DataFlow.Capture : DataFlow.Render))
            throw new InvalidOperationException(Core.Localization.Localized.T("The selected audio device is unavailable.", "Выбранное устройство звука недоступно."));
        return device.ID;
    }

    public static IReadOnlyList<AudioEndpointChoice> List(bool microphone)
    {
        using var enumerator = new MMDeviceEnumerator();
        var items = new List<AudioEndpointChoice>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(microphone ? DataFlow.Capture : DataFlow.Render, DeviceState.Active))
        {
            using (device) items.Add(new(device.ID, device.FriendlyName));
        }
        return items;
    }

    public static string DefaultName(bool microphone)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var device = enumerator.GetDefaultAudioEndpoint(microphone ? DataFlow.Capture : DataFlow.Render, Role.Console);
        return device.FriendlyName;
    }

    public async Task<IAudioEndpointRecorder> CreateAsync(bool microphone, string endpoint, string? processFamily)
    {
        var format = WaveFormat.CreateIeeeFloatWaveFormat(48000, microphone ? 1 : 2);
        if (!microphone && processFamily is not null)
        {
            var name = Path.GetFileNameWithoutExtension(processFamily);
            var target = Process.GetProcessesByName(name).OrderBy(SafeStartTime).FirstOrDefault()
                ?? throw new InvalidOperationException($"{processFamily} stopped before capture could start.");
            return new WasapiEndpointRecorder(await new WasapiRecorderBuilder().WithFormat(format)
                .WithProcessLoopback((uint)target.Id, ProcessLoopbackMode.IncludeTargetProcessTree).BuildAsync().ConfigureAwait(false), null);
        }
        using var enumerator = new MMDeviceEnumerator();
        var device = enumerator.GetDevice(endpoint);
        try
        {
            var builder = new WasapiRecorderBuilder().WithDevice(device).WithFormat(format);
            if (!microphone) builder.WithLoopbackCapture();
            return new WasapiEndpointRecorder(builder.Build(), device);
        }
        catch { device.Dispose(); throw; }
    }

    private static DateTime SafeStartTime(Process process)
    {
        try { return process.StartTime; }
        catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { return DateTime.MaxValue; }
    }
}

internal sealed class AudioPeakMeter
{
    private double peak;
    private long at;
    public double Level => Environment.TickCount64 - Volatile.Read(ref at) > 600 ? 0 : Volatile.Read(ref peak);
    public void Clear() { Volatile.Write(ref peak, 0); Volatile.Write(ref at, Environment.TickCount64); }
    public void Observe(ReadOnlySpan<byte> data, bool silent)
    {
        double maximum = 0;
        if (!silent)
            foreach (var value in MemoryMarshal.Cast<byte, float>(data[..(data.Length / 4 * 4)]))
                if (float.IsFinite(value)) maximum = Math.Max(maximum, Math.Min(1, Math.Abs(value)));
        Volatile.Write(ref peak, maximum);
        Volatile.Write(ref at, Environment.TickCount64);
    }
}
