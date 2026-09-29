using System.Threading;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Velopack;

namespace Amanu.App;

public partial class App : System.Windows.Application
{
    private Mutex? singleInstance;
    private AmanuRuntime? runtime;

    [STAThread]
    private static void Main()
    {
        VelopackApp.Build().SetAutoApplyOnStartup(true).Run();
        var app = new App();
        app.InitializeComponent();
        app.Run();
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        ApplyWindowsTheme();
        SystemEvents.UserPreferenceChanged += WindowsThemeChanged;
        const string mutexName = "Local\\Amanu.Desktop.SingleInstance";
        singleInstance = new Mutex(initiallyOwned: true, mutexName, out var createdNew);
        if (!createdNew)
        {
            System.Windows.MessageBox.Show("Amanu is already running. Look in the notification area.", "Amanu Beta");
            Shutdown();
            return;
        }

        base.OnStartup(e);
        runtime = AmanuRuntime.Create();
        if (!runtime.IsSetupComplete && !e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase))
        {
            new SetupWindow(runtime).ShowDialog();
        }
        var window = new CompactWindow(runtime);
        MainWindow = window;
        runtime.AttachWindow(window);
        if (!e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase) || !runtime.Settings.TrayIcon)
        {
            window.Show();
        }
        _ = runtime.StartAsync();
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        SystemEvents.UserPreferenceChanged -= WindowsThemeChanged;
        if (runtime is not null)
        {
            await runtime.StopForExitAsync();
            await runtime.DisposeAsync();
        }
        singleInstance?.Dispose();
        base.OnExit(e);
    }

    private void WindowsThemeChanged(object sender, UserPreferenceChangedEventArgs e) =>
        Dispatcher.InvokeAsync(ApplyWindowsTheme);

    private void ApplyWindowsTheme()
    {
        using var personalize = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        var dark = personalize?.GetValue("AppsUseLightTheme") is int value && value == 0;
        var colors = dark
            ? new Dictionary<string, string>
            {
                ["WindowBackground"] = "#323234", ["PanelBackground"] = "#38383A",
                ["InputBackground"] = "#414143", ["TextPrimary"] = "#F2F2F4",
                ["MutedText"] = "#B1B1B8", ["BorderColor"] = "#5B5B60",
                ["HoverBackground"] = "#48484C", ["SelectedBackground"] = "#29486A",
                ["Primary"] = "#3B96FF", ["ButtonText"] = "#FFFFFF", ["GoodStatus"] = "#57D37B",
            }
            : new Dictionary<string, string>
            {
                ["WindowBackground"] = "#F5F5F7", ["PanelBackground"] = "#FFFFFF",
                ["InputBackground"] = "#FFFFFF", ["TextPrimary"] = "#242428",
                ["MutedText"] = "#64646B", ["BorderColor"] = "#D5D5DA",
                ["HoverBackground"] = "#EAEAF0", ["SelectedBackground"] = "#E4F0FF",
                ["Primary"] = "#1479E6", ["ButtonText"] = "#FFFFFF", ["GoodStatus"] = "#148044",
            };
        foreach (var (key, hex) in colors)
        {
            Resources[key] = new SolidColorBrush((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));
        }
    }
}
