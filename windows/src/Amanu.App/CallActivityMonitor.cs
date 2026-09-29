using System.Diagnostics;
using Amanu.Core.Recording;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace Amanu.App;

public sealed class CallActivityMonitor : IDisposable
{
    private const float SoundThreshold = 0.0025f;
    private readonly CallProcessMatcher matcher;
    private readonly MMDeviceEnumerator devices = new();

    public CallActivityMonitor(CallProcessMatcher matcher)
    {
        this.matcher = matcher;
    }

    public AudioObservation Observe(DateTimeOffset now)
    {
        string? owner = null;
        var microphoneHasSound = false;
        foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device)
            {
                var sessions = device.AudioSessionManager.Sessions;
                for (var index = 0; index < sessions.Count; index++)
                {
                    using var session = sessions[index];
                    if (session.State != AudioSessionState.AudioSessionStateActive)
                    {
                        continue;
                    }

                    var processName = ProcessName(session.GetProcessID);
                    var matched = processName is null ? null : matcher.Match(processName);
                    if (matched is null)
                    {
                        continue;
                    }

                    owner ??= matched;
                    microphoneHasSound |= session.AudioMeterInformation.MasterPeakValue > SoundThreshold;
                }
            }
        }

        var callAudioHasSound = owner is not null && RenderSessionHasSound(owner);
        return new AudioObservation(
            now,
            owner is not null,
            owner,
            microphoneHasSound,
            callAudioHasSound);
    }

    private bool RenderSessionHasSound(string owner)
    {
        foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                var sessions = device.AudioSessionManager.Sessions;
                for (var index = 0; index < sessions.Count; index++)
                {
                    using var session = sessions[index];
                    var processName = ProcessName(session.GetProcessID);
                    if (processName is not null
                        && string.Equals(matcher.Match(processName), owner, StringComparison.OrdinalIgnoreCase)
                        && session.AudioMeterInformation.MasterPeakValue > SoundThreshold)
                    {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private static string? ProcessName(uint processId)
    {
        try
        {
            return Process.GetProcessById(checked((int)processId)).ProcessName + ".exe";
        }
        catch (Exception exception) when (
            exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    public void Dispose() => devices.Dispose();
}
