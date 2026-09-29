using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velopack;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

public partial class App : System.Windows.Application
{
    private const string InstanceName = "Local\\Amanu.Desktop.SingleInstance";
    private const string DoorbellName = "Local\\Amanu.Desktop.ShowWindow";

    private static AmanuRuntime? runtime;
    private static StatusWindow? status;
    private static TrayIconService? tray;
    private static RecordingsWindow? recordings;
    private static SettingsWindow? settings;
    private static SetupWindow? setup;
    private Mutex? instance;
    private EventWaitHandle? doorbell;

    public static ImageSource? WindowIcon { get; private set; }

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
        // One Amanu per person. Opening it again — from Start, or the installer's
        // shortcut — rings the running one, which shows its window: with both
        // icons off, that is the only way back to it.
        instance = new Mutex(initiallyOwned: true, InstanceName, out var first);
        doorbell = new EventWaitHandle(false, EventResetMode.AutoReset, DoorbellName);
        if (!first)
        {
            doorbell.Set();
            Shutdown();
            return;
        }

#pragma warning disable WPF0001 // The Fluent theme is marked for evaluation in .NET 10; it is the Windows 11 look for WPF.
        ThemeMode = ThemeMode.System;
#pragma warning restore WPF0001
        base.OnStartup(e);
        WindowIcon = LoadIcon();
        runtime = AmanuRuntime.Create();
        var background = e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase);

        status = new StatusWindow(runtime);
        MainWindow = status;
        tray = new TrayIconService(runtime, status);
        ListenForDoorbell();

        // Started at sign-in, Amanu stays out of the way when its tray icon is
        // there to find it by; otherwise the window is the only way in.
        if (!runtime.IsSetupComplete && !background) ShowSetup();
        else if (!background || !runtime.Settings.TrayIcon) status.Reveal();
        if (runtime.RecoveredSessionCount > 0)
            runtime.Notify("Amanu", T($"Recovered {runtime.RecoveredSessionCount} interrupted recording(s); they will be transcribed.",
                $"Восстановлено прерванных записей: {runtime.RecoveredSessionCount}. Они будут расшифрованы."), NotificationKind.Information);
        _ = runtime.StartAsync();
    }

    private void ListenForDoorbell()
    {
        var bell = doorbell!;
        var thread = new Thread(() =>
        {
            try
            {
                while (bell.WaitOne())
                    Dispatcher.InvokeAsync(() => status?.Reveal());
            }
            catch (ObjectDisposedException) { }
        }) { IsBackground = true, Name = "Amanu doorbell" };
        thread.Start();
    }

    private static ImageSource? LoadIcon()
    {
        try
        {
            return BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Amanu.ico"));
        }
        catch (Exception exception) when (exception is IOException or NotSupportedException or UriFormatException)
        {
            return null;
        }
    }

    public static void ShowRecordings()
    {
        if (runtime is null) return;
        if (recordings is null)
        {
            recordings = new RecordingsWindow(runtime);
            recordings.Closed += (_, _) => recordings = null;
        }
        Bring(recordings);
    }

    public static void ShowSettings(int tab)
    {
        if (runtime is null) return;
        if (settings is null)
        {
            settings = new SettingsWindow(runtime);
            settings.Closed += (_, _) => settings = null;
        }
        settings.ShowTab(tab);
        Bring(settings);
    }

    public static void ShowSetup()
    {
        if (runtime is null) return;
        if (setup is null)
        {
            setup = new SetupWindow(runtime);
            setup.Closed += (_, _) =>
            {
                setup = null;
                status?.Reveal();
            };
        }
        Bring(setup);
    }

    public static void ShowAbout() => Bring(new AboutWindow());

    private static void Bring(Window window)
    {
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public static async Task ImportAsync(Window? owner)
    {
        if (runtime is null) return;
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = T("Import a recording", "Импорт записи"),
            Filter = T("Audio and video", "Аудио и видео") + "|*.wav;*.m4a;*.mp3;*.flac;*.ogg;*.aac;*.wma;*.mp4;*.mov;*.mkv;*.webm|"
                     + T("All files", "Все файлы") + "|*.*",
            Multiselect = true,
        };
        if (dialog.ShowDialog(owner) != true) return;
        foreach (var file in dialog.FileNames)
        {
            try { await runtime.ImportAsync(file); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Ui.ShowError(owner, T("Couldn’t import the file", "Не удалось импортировать файл"), exception.Message);
                return;
            }
        }
        ShowRecordings();
    }

    public static async Task CheckForUpdatesAsync()
    {
        if (runtime is not { } current) return;
        bool Busy() => current.State.IsRecording || current.IsProcessing;
        var result = await UpdateService.CheckAsync(Busy, interactive: true, CancellationToken.None);
        if (result.Outcome == UpdateOutcome.Ready && !Busy())
        {
            var answer = System.Windows.MessageBox.Show(result.Message + Environment.NewLine + Environment.NewLine
                + T("Restart Amanu now to install it?", "Перезапустить Amanu и установить сейчас?"),
                T("Update ready", "Обновление готово"), MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (answer == MessageBoxResult.Yes)
            {
                await current.StopForExitAsync();
                UpdateService.RestartIntoUpdate(Busy);
            }
            return;
        }
        if (result.Message.Length > 0)
            System.Windows.MessageBox.Show(result.Message, "Amanu", MessageBoxButton.OK,
                result.Outcome == UpdateOutcome.Failed ? MessageBoxImage.Warning : MessageBoxImage.Information);
    }

    /// <summary>Stops a recording cleanly — its meta.json written, its session queued — and only then exits.</summary>
    public static async Task QuitAsync()
    {
        if (runtime is not null)
        {
            try { await runtime.StopForExitAsync(); }
            catch (Exception exception) when (exception is IOException or InvalidOperationException)
            {
                Ui.ShowError(null, T("Couldn’t stop the recording", "Не удалось остановить запись"), exception.Message);
            }
        }
        status?.AllowClose();
        Current.Shutdown();
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        tray?.Dispose();
        if (runtime is not null)
        {
            await runtime.StopForExitAsync();
            await runtime.DisposeAsync();
        }
        doorbell?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }

    protected override void OnSessionEnding(SessionEndingCancelEventArgs e)
    {
        // Signing out or shutting down: settle the recording while there is time.
        if (runtime is { } current) Task.Run(current.StopForExitAsync).Wait(TimeSpan.FromSeconds(10));
        base.OnSessionEnding(e);
    }
}
