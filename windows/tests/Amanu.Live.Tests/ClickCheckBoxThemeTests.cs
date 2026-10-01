using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Amanu.App;
using Xunit;

#pragma warning disable WPF0001 // Exercise the same native Fluent ThemeMode API as the app.

namespace Amanu.Live.Tests;

public sealed class ClickCheckBoxThemeTests
{
    [Fact]
    public void Status_checkbox_labels_follow_native_light_dark_and_live_theme_changes()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            Window? window = null;
            try
            {
                var automatic = new ClickCheckBox { Content = "Записывать встречи автоматически", IsChecked = true };
                var live = new ClickCheckBox { Content = "Live transcript", IsChecked = true };
                var panel = new StackPanel();
                panel.Children.Add(automatic);
                panel.Children.Add(live);
                window = new Window { Width = 360, Height = 180, Content = panel, ThemeMode = ThemeMode.Light, ShowInTaskbar = false };
                window.Show();
                foreach (var theme in new[] { ThemeMode.Dark, ThemeMode.Light, ThemeMode.Dark })
                {
                    window.ThemeMode = theme;
                    window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
                    window.UpdateLayout();
                    var expected = Assert.IsType<SolidColorBrush>(window.FindResource("TextFillColorPrimaryBrush"));
                    foreach (var control in new[] { automatic, live })
                    {
                        var actual = Assert.IsType<SolidColorBrush>(control.Foreground);
                        Assert.Equal(expected.Color, actual.Color);
                        Assert.Equal(expected.Opacity, actual.Opacity);
                        if (theme == ThemeMode.Dark) Assert.True(actual.Color.R > 200, "Dark checkbox text must be light.");
                        else Assert.True(actual.Color.R < 80, "Light checkbox text must be dark.");
                        Assert.True(control.IsChecked);
                    }
                }
            }
            catch (Exception exception) { failure = exception; }
            finally { window?.Close(); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "Native checkbox theme check did not finish.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
