using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using Amanu.App;
using Amanu.Core.Configuration;
using static Amanu.Core.Localization.Localized;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class AudioDeviceWindowTests
{
    [Fact]
    public void Device_controls_preserve_all_existing_actions_and_remain_scrollable_on_small_screens()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var root = Path.Combine(Path.GetTempPath(), "amanu-device-window-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            AmanuRuntime? runtime = null; StatusWindow? window = null;
            try
            {
                var store = new AppSettingsStore(Path.Combine(root, "config.json"), root);
                store.Save(AppSettings.CreateConservative(root));
                runtime = (AmanuRuntime)typeof(AmanuRuntime).GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance).Single().Invoke([store, store.Load(), root]);
                window = new StatusWindow(runtime);
                Assert.IsType<ScrollViewer>(window.Content);
                var controls = Descendants(window).ToArray();
                Assert.Equal(2, controls.OfType<ComboBox>().Count());
                var buttons = controls.OfType<Button>().Select(button => button.Content?.ToString()).ToArray();
                foreach (var expected in new[] { T("Import…", "Импортировать…"), T("Open recordings folder", "Открыть папку записей"), T("Manage recordings…", "Управление записями…"), T("Settings…", "Настройки…"), T("Test microphone", "Проверить микрофон"), T("Test sound", "Проверить звук") })
                    Assert.Single(buttons, actual => actual == expected);
                Assert.True(window.MaxHeight <= SystemParameters.WorkArea.Height);
            }
            catch (Exception exception) { failure = exception; }
            finally
            {
                if (window is not null) { window.AllowClose(); window.Close(); }
                runtime?.DisposeAsync().AsTask().GetAwaiter().GetResult();
                Directory.Delete(root, true);
            }
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Audio device window did not finish.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
