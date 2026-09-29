namespace Amanu.Core.Recording;

/// <summary>The short recording state shown by the compact control window.</summary>
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
            return new("Не записывает", "Начать запись", "Пауза", false, "");

        var duration = elapsed < TimeSpan.Zero ? TimeSpan.Zero : elapsed;
        var time = duration.TotalHours >= 1
            ? $"{(int)duration.TotalHours}:{duration.Minutes:00}:{duration.Seconds:00}"
            : $"{duration.Minutes}:{duration.Seconds:00}";
        return new(
            state.IsPaused ? "Пауза" : "Запись идёт",
            "Остановить запись",
            state.IsPaused ? "Продолжить" : "Пауза",
            true,
            time);
    }
}
