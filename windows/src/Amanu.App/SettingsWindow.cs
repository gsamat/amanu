using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using static Amanu.Core.Localization.Localized;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Amanu.App;

/// <summary>
/// Settings: the setup form as its first tab and the Advanced tab beside it, with
/// the file they both write named at the bottom.
/// </summary>
internal sealed class SettingsWindow : Window
{
    private readonly AmanuRuntime runtime;
    private readonly SetupForm form;
    private readonly AdvancedSettings advanced;
    private readonly TextBlock problems = Ui.Status("", Ui.Caution);
    private readonly TabControl tabs = new() { Margin = new Thickness(12, 8, 12, 0) };

    public SettingsWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        Title = T("Amanu Settings", "Настройки Amanu");
        Width = 860;
        Height = 820;
        MinWidth = 700;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.WindowIcon;

        form = new SetupForm(runtime, showsConfigProblems: false);
        advanced = new AdvancedSettings(runtime);
        tabs.Items.Add(new TabItem { Header = T("Setup", "Настройка"), Content = Ui.Scroll(form.View) });
        tabs.Items.Add(new TabItem { Header = T("Advanced", "Дополнительно"), Content = Ui.Scroll(advanced.View) });

        var footer = new DockPanel { Margin = new Thickness(Ui.Gutter, 10, Ui.Gutter, 14), LastChildFill = true };
        var reveal = Ui.Button(T("Show file", "Показать файл"), RevealConfig);
        DockPanel.SetDock(reveal, Dock.Right);
        reveal.Margin = new Thickness(12, 0, 0, 0);
        footer.Children.Add(reveal);
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        problems.Margin = new Thickness(0, 0, 0, 6);
        words.Children.Add(problems);
        words.Children.Add(new TextBlock
        {
            Text = runtime.ConfigPath,
            FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            HorizontalAlignment = HorizontalAlignment.Left,
        }.Brush(TextBlock.ForegroundProperty, Ui.Secondary));
        footer.Children.Add(words);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(tabs);
        Content = root;

        runtime.SettingsChanged += OnSettingsChanged;
        Closed += (_, _) =>
        {
            runtime.SettingsChanged -= OnSettingsChanged;
            form.Detach();
            advanced.Detach();
        };
        ShowProblems();
        runtime.TrackSettingsOpened();
    }

    public void ShowTab(int index) => tabs.SelectedIndex = index;

    private void OnSettingsChanged(object? sender, EventArgs e) => Dispatcher.InvokeAsync(ShowProblems);

    /// <summary>Said once, under both tabs, rather than at the top of one of them.</summary>
    private void ShowProblems()
    {
        var list = runtime.ConfigProblems;
        problems.Text = string.Join(Environment.NewLine, list.Select(problem => problem.Explanation));
        problems.Visibility = list.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RevealConfig()
    {
        if (System.IO.File.Exists(runtime.ConfigPath))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{runtime.ConfigPath}\"") { UseShellExecute = true });
        else
            AmanuRuntime.Open(System.IO.Path.GetDirectoryName(runtime.ConfigPath)!);
    }
}

/// <summary>
/// First run: the same form, with a footer that says what is still missing and a
/// way to leave it for later.
/// </summary>
internal sealed class SetupWindow : Window
{
    private readonly SetupForm form;
    private readonly TextBlock remaining = Ui.Status();

    public SetupWindow(AmanuRuntime runtime)
    {
        Title = T("Setting up Amanu", "Первая настройка Amanu");
        Width = 860;
        Height = 820;
        MinWidth = 700;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.WindowIcon;

        form = new SetupForm(runtime);
        var footer = new DockPanel { Margin = new Thickness(Ui.Gutter, 12, Ui.Gutter, 14) };
        var done = Ui.Button(T("Done", "Готово"), async () =>
        {
            await runtime.CompleteSetupAsync();
            Close();
        }, accent: true);
        done.IsDefault = true;
        var later = Ui.Button(T("Later", "Позже"), Close);
        later.Margin = new Thickness(8, 0, 0, 0);
        done.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(done, Dock.Right);
        DockPanel.SetDock(later, Dock.Right);
        footer.Children.Add(done);
        footer.Children.Add(later);
        footer.Children.Add(remaining);

        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(Ui.Scroll(form.View));
        Content = root;

        form.StateChanged += (_, _) => ShowRemaining();
        Closed += (_, _) => form.Detach();
        ShowRemaining();
    }

    private void ShowRemaining()
    {
        var left = form.Outstanding();
        remaining.Text = left.Count == 0
            ? T("All set. Everything here can be changed later in Settings.", "Всё готово. Всё это можно поменять потом в настройках.")
            : T("Still missing: ", "Осталось: ") + string.Join(", ", left);
    }
}

/// <summary>The version, and where Amanu comes from.</summary>
internal sealed class AboutWindow : Window
{
    public AboutWindow()
    {
        Title = T("About Amanu", "О программе Amanu");
        SizeToContent = SizeToContent.WidthAndHeight;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.WindowIcon;
        var stack = new StackPanel { Margin = new Thickness(32, 24, 32, 24), MaxWidth = 380 };
        stack.Children.Add(new System.Windows.Controls.Image { Source = App.WindowIcon, Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Left });
        var name = Ui.Title("Amanu");
        name.FontSize = 20;
        name.FontWeight = FontWeights.SemiBold;
        name.Margin = new Thickness(0, 12, 0, 0);
        stack.Children.Add(name);
        stack.Children.Add(Ui.Detail(T($"Version {AmanuRuntime.AppVersion} · beta for Windows", $"Версия {AmanuRuntime.AppVersion} · бета для Windows")));
        var about = Ui.Detail(T("Records meetings on this computer, transcribes them, and writes down what was decided.",
            "Записывает встречи на этом компьютере, расшифровывает их и записывает, о чём договорились."));
        about.Margin = new Thickness(0, 12, 0, 0);
        stack.Children.Add(about);
        var links = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        links.Children.Add(Ui.Link("amanu.me", "https://amanu.me"));
        var privacy = Ui.Link(T("Privacy", "Приватность"), "https://github.com/gsamat/amanu/blob/master/PRIVACY.md");
        privacy.Margin = new Thickness(16, 0, 0, 0);
        links.Children.Add(privacy);
        stack.Children.Add(links);
        Content = stack;
    }
}
