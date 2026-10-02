using static Amanu.Core.Localization.Localized;

namespace Amanu.Core.Recording;

/// <summary>The short recording state shown by the status window and the tray.</summary>
public sealed record RecordingDisplay(
    string Heading,
    string RecordAction,
    string PauseAction,
    bool CanPause,
    string Elapsed)
{
    public static RecordingDisplay From(RecordingState state, TimeSpan elapsed)
    {
        if (!state.IsRecording)
            return new(T("ready", "готов"), T("Start recording", "Начать запись"), T("Pause", "Пауза"), false, "");

        var time = Clock(elapsed);
        return new(
            state.IsPaused ? T("paused", "пауза") : T("recording", "запись"),
            T("Stop recording", "Остановить запись"),
            state.IsPaused ? T("Resume", "Продолжить") : T("Pause", "Пауза"),
            true,
            time);
    }

    /// <summary>"4:05", or "1:04:05" past the hour.</summary>
    public static string Clock(TimeSpan elapsed)
    {
        var duration = elapsed < TimeSpan.Zero ? TimeSpan.Zero : elapsed;
        return duration.TotalHours >= 1
            ? $"{(int)duration.TotalHours}:{duration.Minutes:00}:{duration.Seconds:00}"
            : $"{duration.Minutes}:{duration.Seconds:00}";
    }
}
