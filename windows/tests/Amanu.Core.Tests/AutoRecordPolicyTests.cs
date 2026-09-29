using Amanu.Core.Recording;

namespace Amanu.Core.Tests;

public sealed class AutoRecordPolicyTests
{
    private static readonly DateTimeOffset Noon = new(2026, 9, 20, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Configured_call_must_hold_the_microphone_for_the_start_delay()
    {
        var policy = new AutoRecordPolicy(new AutoRecordOptions(
            Enabled: true,
            StartDelay: TimeSpan.FromSeconds(12),
            StopDelay: TimeSpan.FromSeconds(15),
            MinimumDuration: TimeSpan.FromSeconds(45),
            SilenceStop: TimeSpan.FromMinutes(10),
            MaximumDuration: TimeSpan.FromHours(5)));

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon, micOwner: "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddSeconds(11), micOwner: "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.Start,
            policy.Observe(Observation(Noon.AddSeconds(12), micOwner: "Zoom.exe")));
    }

    [Fact]
    public void An_unconfigured_process_never_starts_a_recording()
    {
        var policy = Policy();

        policy.Observe(Observation(Noon, micOwner: "audacity.exe", configured: false));

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(1), micOwner: "audacity.exe", configured: false)));
    }

    [Fact]
    public void An_automatic_recording_stops_after_the_call_releases_the_microphone()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddSeconds(60), micOwner: null)));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddSeconds(74), micOwner: null)));
        Assert.Equal(AutoRecordDecision.Stop,
            policy.Observe(Observation(Noon.AddSeconds(75), micOwner: null)));
    }

    [Fact]
    public void Manual_stop_suppresses_restart_until_the_call_has_ended()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);
        policy.ManualStop(Noon.AddMinutes(1));

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(2), micOwner: "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(3), micOwner: null)));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(3).AddSeconds(14), micOwner: null)));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(3).AddSeconds(15), micOwner: null)));

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(Observation(Noon.AddMinutes(4), micOwner: "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.Start,
            policy.Observe(Observation(Noon.AddMinutes(4).AddSeconds(12), micOwner: "Zoom.exe")));
    }

    [Fact]
    public void Two_silent_tracks_stop_a_stuck_call_after_the_silence_limit()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);

        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(SilentObservation(Noon.AddMinutes(1), "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.None,
            policy.Observe(SilentObservation(Noon.AddMinutes(10).AddSeconds(59), "Zoom.exe")));
        Assert.Equal(AutoRecordDecision.Stop,
            policy.Observe(SilentObservation(Noon.AddMinutes(11), "Zoom.exe")));
    }

    [Fact]
    public void Automatic_stop_rearms_policy_for_the_next_call()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);

        policy.RecordingStopped();
        policy.Observe(Observation(Noon.AddMinutes(2), micOwner: "Teams.exe"));

        Assert.Equal(AutoRecordDecision.Start,
            policy.Observe(Observation(Noon.AddMinutes(2).AddSeconds(12), micOwner: "Teams.exe")));
    }

    [Fact]
    public void Automatic_recording_can_be_enabled_without_restarting_the_app()
    {
        var policy = new AutoRecordPolicy(new AutoRecordOptions(
            Enabled: false,
            StartDelay: TimeSpan.FromSeconds(12),
            StopDelay: TimeSpan.FromSeconds(15),
            MinimumDuration: TimeSpan.FromSeconds(45),
            SilenceStop: TimeSpan.FromMinutes(10),
            MaximumDuration: TimeSpan.FromHours(5)));

        policy.Observe(Observation(Noon, micOwner: "Zoom.exe"));
        policy.SetEnabled(true);
        policy.Observe(Observation(Noon.AddMinutes(1), micOwner: "Zoom.exe"));

        Assert.Equal(AutoRecordDecision.Start,
            policy.Observe(Observation(Noon.AddMinutes(1).AddSeconds(12), micOwner: "Zoom.exe")));
    }

    private static AutoRecordPolicy Policy() => new(new AutoRecordOptions(
        Enabled: true,
        StartDelay: TimeSpan.FromSeconds(12),
        StopDelay: TimeSpan.FromSeconds(15),
        MinimumDuration: TimeSpan.FromSeconds(45),
        SilenceStop: TimeSpan.FromMinutes(10),
        MaximumDuration: TimeSpan.FromHours(5)));

    private static AudioObservation Observation(
        DateTimeOffset at,
        string? micOwner,
        bool configured = true) => new(
            At: at,
            ConfiguredCallProcessOwnsMicrophone: configured && micOwner is not null,
            MicrophoneOwner: micOwner,
            MicrophoneHasSound: micOwner is not null,
            CallAudioHasSound: micOwner is not null);

    private static AudioObservation SilentObservation(DateTimeOffset at, string micOwner) => new(
        At: at,
        ConfiguredCallProcessOwnsMicrophone: true,
        MicrophoneOwner: micOwner,
        MicrophoneHasSound: false,
        CallAudioHasSound: false);
}
