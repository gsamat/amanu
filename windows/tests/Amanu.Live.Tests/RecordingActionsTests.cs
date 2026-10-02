using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Windows.Controls;
using Amanu.App;
using Amanu.Core.Configuration;
using Amanu.Core.Localization;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class RecordingActionsTests
{
    [Fact]
    public void A_recording_without_audio_explains_disabled_audio_actions_in_its_details() => OnSta(() =>
    {
        WithWindow((window, root) =>
        {
            Select(window, Item(root, false), null);
            Assert.False(Field<Button>(window, "retranscribe").IsEnabled);
            Assert.False(Field<Button>(window, "listen").IsEnabled);
            Assert.Contains(Localized.T("The audio was not kept for this recording.", "Звук этой записи не сохранён."),
                Field<TextBlock>(window, "processingStatus").Text);
        });
    });

    [Fact]
    public void Selecting_an_idle_completed_recording_enables_its_audio_actions_while_another_is_busy() => OnSta(() =>
    {
        WithWindow((window, root) =>
        {
            var busy = Item(root, true) with { Transcript = ProcessingStep.Pending, Summary = ProcessingStep.Pending };
            Select(window, busy, new(root, "transcribing", "Transcribing", true));
            Assert.False(Field<Button>(window, "retranscribe").IsEnabled);
            Assert.False(Field<Button>(window, "delete").IsEnabled);
            var completed = Item(root, true) with { Directory = Path.Combine(root, "other") };
            Select(window, completed, null);
            Assert.True(Field<Button>(window, "retranscribe").IsEnabled);
            Assert.True(Field<Button>(window, "listen").IsEnabled);
            Assert.True(Field<Button>(window, "delete").IsEnabled);
            Assert.False(Field<Button>(window, "finish").IsEnabled); // Nothing left to finish.
        });
    });

    private static SessionListItem Item(string directory, bool audio) => new(directory, "Test", DateTimeOffset.UtcNow,
        1, "manual", "parakeet", ProcessingStep.Done, ProcessingStep.Done, ProcessingStep.Done, 0, audio);

    private static void Select(RecordingsWindow window, SessionListItem item, ProcessingStatus? status)
    {
        var row = Activator.CreateInstance(typeof(RecordingsWindow).GetNestedType("Row", BindingFlags.NonPublic)!, item, status)!;
        var grid = Field<DataGrid>(window, "grid");
        grid.ItemsSource = new[] { row };
        grid.SelectedItem = row;
        ((Task)typeof(RecordingsWindow).GetMethod("ShowSelectedAsync", BindingFlags.Instance | BindingFlags.NonPublic)!
            .Invoke(window, null)!).GetAwaiter().GetResult();
    }

    private static T Field<T>(RecordingsWindow window, string name) =>
        (T)typeof(RecordingsWindow).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(window)!;

    private static void WithWindow(Action<RecordingsWindow, string> test)
    {
        var root = Path.Combine(Path.GetTempPath(), "amanu-actions-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var settings = AppSettings.CreateConservative(root);
        settings.RecordingsDirectory = Path.Combine(root, "recordings");
        File.WriteAllText(Path.Combine(root, "config.json"), System.Text.Json.JsonSerializer.Serialize(settings, AppSettings.JsonOptions));
        var store = new AppSettingsStore(Path.Combine(root, "config.json"), root);
        var runtime = (AmanuRuntime)typeof(AmanuRuntime).GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance).Single()
            .Invoke([store, store.Load(), root]);
        try
        {
            var window = new RecordingsWindow(runtime);
            try { test(window, root); }
            finally { window.Close(); }
        }
        finally
        {
            runtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
            Directory.Delete(root, true);
        }
    }

    private static void OnSta(Action test)
    {
        Exception? error = null;
        var thread = new Thread(() => { try { test(); } catch (Exception exception) { error = exception; } });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(20)), "The recordings UI test did not finish.");
        if (error is not null) ExceptionDispatchInfo.Capture(error).Throw();
    }
}
