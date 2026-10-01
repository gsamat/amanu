using static Amanu.Core.Localization.Localized;

namespace Amanu.Core.Recording;

public enum AutoRecordAction
{
    None,
    Start,
    Stop,
}

/// <summary>What the policy wants done, and for a stop, why.</summary>
public readonly record struct AutoRecordDecision(AutoRecordAction Action, string? StopReason = null)
{
    public static AutoRecordDecision None => new(AutoRecordAction.None);
    public static AutoRecordDecision Start => new(AutoRecordAction.Start);
    public static AutoRecordDecision Stop(string reason) => new(AutoRecordAction.Stop, reason);
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

public enum AutoRecordPhase
{
    /// <summary>Nothing of ours is recording and nothing holds the loop back.</summary>
    Watching,
    /// <summary>A recording is running, ours or the person's; the stop rules own it.</summary>
    Recording,
    /// <summary>
    /// A recording ended while its call may well still be going — the person
    /// stopped it, or a backstop did. Nothing starts again until the mic has been
    /// let go for the stop delay: the call is over, and the next one is a new call.
    /// </summary>
    StandingDown,
    /// <summary>A start failed. Nothing is tried again before the wait is over.</summary>
    BackingOff,
}

/// <summary>
/// Decides on its own when a meeting starts and ends, as an explicit state
/// machine. Timestamps alone used to stand in for the state on macOS, and they
/// re-armed by themselves: a backstop stop left the mic clock running, so an app
/// that never let go of the microphone — exactly what the backstops exist for —
/// was recording again seconds later, for as long as it held on.
/// </summary>
/// <remarks>
/// The duration ceiling applies to every recording, manual ones included and
/// with auto-record off; the other stop rules only to automatic recordings. If
/// you pressed the button, only you decide when it stops.
/// </remarks>
public sealed class AutoRecordPolicy(AutoRecordOptions initial)
{
    public static readonly TimeSpan FirstRetry = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan LongestRetry = TimeSpan.FromMinutes(10);
    private static readonly HashSet<string> BackstopReasons = ["max-duration", "silence"];

    private AutoRecordOptions options = initial;
    private DateTimeOffset? microphoneHeldSince;
    private DateTimeOffset? microphoneReleasedSince;
    private DateTimeOffset? bothTracksSilentSince;
    private DateTimeOffset? recordingStartedAt;
    private DateTimeOffset? backingOffUntil;
    private bool manualRecording;
    private bool standingDownAfterManualStop;
    private int startFailures;

    public AutoRecordPhase Phase { get; private set; } = AutoRecordPhase.Watching;

    /// <summary>What the policy is thinking, for the window: "why didn't it record?"</summary>
    public string LastDecision { get; private set; } = T("waiting for a call", "жду звонка");

    public bool Enabled => options.Enabled;

    public AutoRecordOptions Options => options;

    public void Update(AutoRecordOptions value)
    {
        options = value;
        if (!value.Enabled) microphoneHeldSince = null;
    }

    public void SetEnabled(bool value) => Update(options with { Enabled = value });

    public void RecordingStarted(DateTimeOffset at, bool manual)
    {
        Phase = AutoRecordPhase.Recording;
        recordingStartedAt = at;
        manualRecording = manual;
        microphoneReleasedSince = null;
        bothTracksSilentSince = null;
        backingOffUntil = null;
        if (!manual) startFailures = 0;
    }

    /// <summary>A recording ended; <paramref name="reason"/> is its stop reason.</summary>
    public void RecordingStopped(string reason)
    {
        var manual = reason is "manual";
        recordingStartedAt = null;
        manualRecording = false;
        microphoneHeldSince = null;
        microphoneReleasedSince = null;
        bothTracksSilentSince = null;
        if (manual || BackstopReasons.Contains(reason))
        {
            Phase = AutoRecordPhase.StandingDown;
            standingDownAfterManualStop = manual;
        }
        else Phase = AutoRecordPhase.Watching;
    }

    /// <summary>
    /// An automatic start failed. The first retry is soon, in case the refusal was a
    /// device changing hands; after that each wait doubles, up to ten minutes.
    /// </summary>
    public TimeSpan StartFailed(DateTimeOffset at)
    {
        startFailures++;
        var wait = TimeSpan.FromTicks(Math.Min(
            LongestRetry.Ticks,
            FirstRetry.Ticks * (long)Math.Pow(2, Math.Min(startFailures - 1, 10))));
        backingOffUntil = at + wait;
        microphoneHeldSince = null;
        Phase = AutoRecordPhase.BackingOff;
        return wait;
    }

    /// <summary>The duration ceiling, which holds for every recording whatever else is on.</summary>
    public bool CeilingReached(DateTimeOffset now) =>
        recordingStartedAt is { } started && now - started >= options.MaximumDuration;

    public AutoRecordDecision Observe(AudioObservation observation)
    {
        if (recordingStartedAt is { } started) return ObserveRecording(observation, started);

        var owned = observation.ConfiguredCallProcessOwnsMicrophone;
        if (owned) microphoneReleasedSince = null;
        else microphoneReleasedSince ??= observation.At;
        var callOver = !owned && observation.At - microphoneReleasedSince >= options.StopDelay;
        // A new call is a new episode: whatever failed during the last one says
        // nothing about this one.
        if (callOver) startFailures = 0;

        switch (Phase)
        {
            case AutoRecordPhase.StandingDown when !callOver:
                LastDecision = standingDownAfterManualStop
                    ? T("paused after a manual stop until the call ends", "пауза после ручной остановки до конца звонка")
                    : T("stopped by a safety limit — waiting for the call app to let go of the mic",
                        "остановлено ограничителем — жду, пока приложение освободит микрофон");
                return AutoRecordDecision.None;
            case AutoRecordPhase.BackingOff when backingOffUntil is { } until && observation.At < until:
                var seconds = (int)Math.Ceiling((until - observation.At).TotalSeconds);
                LastDecision = T($"couldn't start recording — trying again in {seconds}s",
                                 $"не удалось начать запись — повторю через {seconds} с");
                return AutoRecordDecision.None;
            case AutoRecordPhase.StandingDown or AutoRecordPhase.BackingOff or AutoRecordPhase.Recording:
                Phase = AutoRecordPhase.Watching;
                break;
        }

        if (!options.Enabled)
        {
            microphoneHeldSince = null;
            LastDecision = T("auto-record is off", "автозапись выключена");
            return AutoRecordDecision.None;
        }
        if (!owned)
        {
            microphoneHeldSince = null;
            LastDecision = T("waiting for a call", "жду звонка");
            return AutoRecordDecision.None;
        }

        microphoneHeldSince ??= observation.At;
        var held = observation.At - microphoneHeldSince.Value;
        if (held >= options.StartDelay) return AutoRecordDecision.Start;
        var remaining = (int)Math.Ceiling((options.StartDelay - held).TotalSeconds);
        LastDecision = T($"{observation.MicrophoneOwner} took the mic — starting in {remaining}s",
                         $"{observation.MicrophoneOwner} взял микрофон — начну через {remaining} с");
        return AutoRecordDecision.None;
    }

    private AutoRecordDecision ObserveRecording(AudioObservation observation, DateTimeOffset started)
    {
        if (observation.At - started >= options.MaximumDuration) return AutoRecordDecision.Stop("max-duration");
        if (manualRecording) return AutoRecordDecision.None;

        if (observation.ConfiguredCallProcessOwnsMicrophone) microphoneReleasedSince = null;
        else microphoneReleasedSince ??= observation.At;

        if (observation.MicrophoneHasSound || observation.CallAudioHasSound) bothTracksSilentSince = null;
        else bothTracksSilentSince ??= observation.At;

        if (microphoneReleasedSince is { } released && observation.At - released >= options.StopDelay)
            return AutoRecordDecision.Stop("call-ended");
        if (bothTracksSilentSince is { } silent && observation.At - silent >= options.SilenceStop)
            return AutoRecordDecision.Stop("silence");
        return AutoRecordDecision.None;
    }

    /// <summary>
    /// Whether a finished automatic recording was too short to have been a meeting.
    /// The length compared is the meeting's, not the file's: the recording runs on
    /// for as long as the stop rule waits, and left in terms of the file the
    /// comparison could never be true — which is how the macOS discard once
    /// shipped unreachable and kept every nineteen-second join.
    /// </summary>
    public static bool ShouldDiscard(bool manual, string reason, TimeSpan duration, AutoRecordOptions options)
    {
        if (manual) return false;
        TimeSpan? quiet = reason switch
        {
            "call-ended" => options.StopDelay,
            "silence" => options.SilenceStop,
            _ => null,
        };
        return quiet is { } trailing && duration - trailing < options.MinimumDuration;
    }
}
