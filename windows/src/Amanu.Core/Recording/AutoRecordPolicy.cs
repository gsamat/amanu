namespace Amanu.Core.Recording;

public enum AutoRecordDecision
{
    None,
    Start,
    Stop,
}

public sealed record AutoRecordOptions(
    bool Enabled,
    TimeSpan StartDelay,
    TimeSpan StopDelay,
    TimeSpan MinimumDuration,
    TimeSpan SilenceStop,
    TimeSpan MaximumDuration);

public sealed record AudioObservation(
    DateTimeOffset At,
    bool ConfiguredCallProcessOwnsMicrophone,
    string? MicrophoneOwner,
    bool MicrophoneHasSound,
    bool CallAudioHasSound);

public sealed class AutoRecordPolicy(AutoRecordOptions options)
{
    private bool enabled = options.Enabled;
    private DateTimeOffset? microphoneHeldSince;
    private DateTimeOffset? microphoneReleasedSince;
    private DateTimeOffset? bothTracksSilentSince;
    private DateTimeOffset? recordingStartedAt;
    private bool manualRecording;
    private bool suppressedAfterManualStop;

    public void RecordingStarted(DateTimeOffset at, bool manual)
    {
        recordingStartedAt = at;
        manualRecording = manual;
        microphoneReleasedSince = null;
        bothTracksSilentSince = null;
        suppressedAfterManualStop = false;
    }

    public void ManualStop(DateTimeOffset at)
    {
        RecordingStopped();
        suppressedAfterManualStop = true;
        _ = at;
    }

    public void RecordingStopped()
    {
        recordingStartedAt = null;
        manualRecording = false;
        microphoneHeldSince = null;
        microphoneReleasedSince = null;
        bothTracksSilentSince = null;
    }

    public void SetEnabled(bool value)
    {
        enabled = value;
        if (!enabled)
        {
            microphoneHeldSince = null;
        }
    }

    public AutoRecordDecision Observe(AudioObservation observation)
    {
        if (recordingStartedAt is { } started)
        {
            return ObserveRecording(observation, started);
        }

        if (suppressedAfterManualStop)
        {
            if (observation.ConfiguredCallProcessOwnsMicrophone)
            {
                microphoneReleasedSince = null;
                return AutoRecordDecision.None;
            }

            microphoneReleasedSince ??= observation.At;
            if (observation.At - microphoneReleasedSince >= options.StopDelay)
            {
                suppressedAfterManualStop = false;
                microphoneReleasedSince = null;
            }
            return AutoRecordDecision.None;
        }

        if (!enabled || !observation.ConfiguredCallProcessOwnsMicrophone)
        {
            microphoneHeldSince = null;
            return AutoRecordDecision.None;
        }

        microphoneHeldSince ??= observation.At;
        if (observation.At - microphoneHeldSince >= options.StartDelay)
        {
            return AutoRecordDecision.Start;
        }

        return AutoRecordDecision.None;
    }

    private AutoRecordDecision ObserveRecording(AudioObservation observation, DateTimeOffset started)
    {
        var elapsed = observation.At - started;
        if (elapsed >= options.MaximumDuration)
        {
            return AutoRecordDecision.Stop;
        }

        if (manualRecording)
        {
            return AutoRecordDecision.None;
        }

        if (observation.ConfiguredCallProcessOwnsMicrophone)
        {
            microphoneReleasedSince = null;
        }
        else
        {
            microphoneReleasedSince ??= observation.At;
        }

        if (observation.MicrophoneHasSound || observation.CallAudioHasSound)
        {
            bothTracksSilentSince = null;
        }
        else
        {
            bothTracksSilentSince ??= observation.At;
        }

        if (elapsed < options.MinimumDuration)
        {
            return AutoRecordDecision.None;
        }

        if (microphoneReleasedSince is { } released
            && observation.At - released >= options.StopDelay)
        {
            return AutoRecordDecision.Stop;
        }

        if (bothTracksSilentSince is { } silent
            && observation.At - silent >= options.SilenceStop)
        {
            return AutoRecordDecision.Stop;
        }

        return AutoRecordDecision.None;
    }
}
