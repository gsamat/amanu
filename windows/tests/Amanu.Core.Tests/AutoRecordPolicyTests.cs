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
        Assert.Equal(AutoRecordDecision.Stop("call-ended"),
            policy.Observe(Observation(Noon.AddSeconds(75), micOwner: null)));
    }

    [Fact]
    public void Manual_stop_suppresses_restart_until_the_call_has_ended()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);
        policy.RecordingStopped("manual");

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
        Assert.Equal(AutoRecordDecision.Stop("silence"),
            policy.Observe(SilentObservation(Noon.AddMinutes(11), "Zoom.exe")));
    }

    [Fact]
    public void Automatic_stop_rearms_policy_for_the_next_call()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);

        policy.RecordingStopped("call-ended");
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

    [Fact]
    public void A_backstop_stop_does_not_rearm_while_the_app_still_holds_the_mic()
    {
        var policy = Policy();
        policy.RecordingStarted(Noon, manual: false);
        policy.Observe(SilentObservation(Noon.AddMinutes(1), "Zoom.exe"));
        Assert.Equal(AutoRecordDecision.Stop("silence"),
            policy.Observe(SilentObservation(Noon.AddMinutes(11), "Zoom.exe")));
        policy.RecordingStopped("silence");

        for (var second = 5; second <= 120; second += 5)
            Assert.Equal(AutoRecordDecision.None,
                policy.Observe(SilentObservation(Noon.AddMinutes(11).AddSeconds(second), "Zoom.exe")));
        Assert.Equal(AutoRecordPhase.StandingDown, policy.Phase);

        policy.Observe(Observation(Noon.AddMinutes(20), micOwner: null));
        policy.Observe(Observation(Noon.AddMinutes(20).AddSeconds(15), micOwner: null));
        policy.Observe(Observation(Noon.AddMinutes(21), micOwner: "Zoom.exe"));
        Assert.Equal(AutoRecordDecision.Start,
            policy.Observe(Observation(Noon.AddMinutes(21).AddSeconds(12), micOwner: "Zoom.exe")));
    }

    [Fact]
    public void The_duration_ceiling_stops_a_manual_recording_too()
    {
        var policy = Policy();
        policy.SetEnabled(false);
        policy.RecordingStarted(Noon, manual: true);

        Assert.False(policy.CeilingReached(Noon.AddHours(4)));
        Assert.True(policy.CeilingReached(Noon.AddHours(5)));
        Assert.Equal(AutoRecordDecision.Stop("max-duration"),
            policy.Observe(Observation(Noon.AddHours(5), micOwner: null)));
    }

    [Fact]
    public void A_failing_start_backs_off_doubling_up_to_ten_minutes()
    {
        var policy = Policy();
        Assert.Equal(TimeSpan.FromSeconds(30), policy.StartFailed(Noon));
        Assert.Equal(AutoRecordDecision.None, policy.Observe(Observation(Noon.AddSeconds(29), micOwner: "Zoom.exe")));
        Assert.Equal(TimeSpan.FromSeconds(60), policy.StartFailed(Noon.AddSeconds(45)));
        Assert.Equal(TimeSpan.FromSeconds(120), policy.StartFailed(Noon.AddMinutes(2)));
        for (var attempt = 0; attempt < 10; attempt++) policy.StartFailed(Noon.AddMinutes(3));
        Assert.Equal(TimeSpan.FromMinutes(10), policy.StartFailed(Noon.AddMinutes(4)));
    }

    [Theory]
    [InlineData(false, "call-ended", 59, true)]
    [InlineData(false, "call-ended", 61, false)]
    [InlineData(false, "max-duration", 20, false)]
    [InlineData(true, "call-ended", 5, false)]
    public void Only_short_automatic_meetings_are_discarded_measured_without_the_stop_wait(
        bool manual, string reason, int seconds, bool discard)
    {
        var options = new AutoRecordOptions(true, TimeSpan.FromSeconds(12), TimeSpan.FromSeconds(15),
            TimeSpan.FromSeconds(45), TimeSpan.FromMinutes(10), TimeSpan.FromHours(5));
        Assert.Equal(discard, AutoRecordPolicy.ShouldDiscard(manual, reason, TimeSpan.FromSeconds(seconds), options));
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
