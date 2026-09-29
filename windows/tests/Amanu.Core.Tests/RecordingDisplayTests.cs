using Amanu.Core.Localization;
using Amanu.Core.Recording;

namespace Amanu.Core.Tests;

public sealed class RecordingDisplayTests
{
    [Fact]
    public void Ready_state_offers_start_and_disables_pause()
    {
        using var russian = Localized.Use(InterfaceLanguage.Russian);
        var display = RecordingDisplay.From(RecordingState.Ready, TimeSpan.Zero);

        Assert.Equal("не записывает", display.Heading);
        Assert.Equal("Начать запись", display.RecordAction);
        Assert.False(display.CanPause);
        Assert.Empty(display.Elapsed);
    }

    [Fact]
    public void Recording_state_shows_elapsed_time_and_stop_action()
    {
        var state = new RecordingState(true, false, DateTimeOffset.UtcNow, null, null, null);
        using var russian = Localized.Use(InterfaceLanguage.Russian);

        var display = RecordingDisplay.From(state, TimeSpan.FromSeconds(754));

        Assert.Equal("запись", display.Heading);
        Assert.Equal("12:34", display.Elapsed);
        Assert.Equal("Остановить запись", display.RecordAction);
        Assert.Equal("Пауза", display.PauseAction);
        Assert.True(display.CanPause);
    }

    [Fact]
    public void Paused_state_keeps_stop_available_and_offers_resume()
    {
        var state = new RecordingState(true, true, DateTimeOffset.UtcNow, null, null, null);

        var display = RecordingDisplay.From(state, TimeSpan.FromHours(1) + TimeSpan.FromSeconds(5));

        Assert.Equal("paused", display.Heading);
        Assert.Equal("1:00:05", display.Elapsed);
        Assert.Equal("Stop recording", display.RecordAction);
        Assert.Equal("Resume", display.PauseAction);
        Assert.True(display.CanPause);
    }
}
