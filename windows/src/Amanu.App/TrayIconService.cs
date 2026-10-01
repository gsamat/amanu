using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Amanu.Core.Recording;
using static Amanu.Core.Localization.Localized;
using ContextMenu = System.Windows.Controls.ContextMenu;
using MenuItem = System.Windows.Controls.MenuItem;
using Separator = System.Windows.Controls.Separator;

namespace Amanu.App;

/// <summary>
/// The icon by the clock and its menu — the same items, in the same order, as the
/// macOS menu-bar menu. A left click opens the window, as it does for every tray
/// icon on Windows; the right click opens the menu, drawn by WPF so it wears the
/// same Windows 11 style as the windows rather than the old WinForms one.
/// </summary>
internal sealed class TrayIconService : IDisposable
{
    private readonly AmanuRuntime runtime;
    private readonly System.Windows.Forms.NotifyIcon icon;
    private readonly Icon idleIcon;
    private readonly Icon recordingIcon;
    private readonly Icon pausedIcon;
    private readonly MenuItem stateItem = new() { IsEnabled = false };
    private readonly MenuItem recordItem = new();
    private readonly MenuItem pauseItem = new();
    private readonly MenuItem autoRecordItem = new() { Header = T("Record meetings automatically", "Записывать встречи автоматически"), IsCheckable = true };
    private readonly ContextMenu menu = new();
    private readonly System.Windows.Threading.DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };

    public TrayIconService(AmanuRuntime runtime, StatusWindow window)
    {
        this.runtime = runtime;
        idleIcon = LoadIcon();
        recordingIcon = Badge(idleIcon, Color.FromArgb(0xE8, 0x3B, 0x3B));
        pausedIcon = Badge(idleIcon, Color.FromArgb(0xE8, 0x9A, 0x1C));

        recordItem.Click += async (_, _) => await window.ToggleRecordingAsync();
        pauseItem.Click += async (_, _) => await window.TogglePauseAsync();
        autoRecordItem.Click += (_, _) =>
        {
            if (!Ui.TryUpdate(null, () => runtime.SetAutoRecord(autoRecordItem.IsChecked))) Refresh();
        };
        menu.Items.Add(stateItem);
        menu.Items.Add(recordItem);
        menu.Items.Add(pauseItem);
        menu.Items.Add(new Separator());
        menu.Items.Add(autoRecordItem);
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(T("Show Amanu window", "Показать окно Amanu"), window.Reveal));
        menu.Items.Add(Item(T("Open recordings folder", "Открыть папку записей"), () =>
        {
            runtime.TrackArtifact("recordings_root");
            AmanuRuntime.Open(runtime.Settings.RecordingsDirectory);
        }));
        menu.Items.Add(Item(T("Manage recordings…", "Управление записями…"), App.ShowRecordings));
        menu.Items.Add(Item(T("Import…", "Импортировать…"), () => _ = App.ImportAsync(null)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(T("Settings…", "Настройки…"), () => App.ShowSettings(0)));
        menu.Items.Add(Item(T("Setup…", "Первая настройка…"), App.ShowSetup));
        menu.Items.Add(Item(T("Check for updates…", "Проверить обновления…"), () => _ = App.CheckForUpdatesAsync()));
        menu.Items.Add(Item(T("About Amanu", "О программе Amanu"), App.ShowAbout));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(T("Quit Amanu", "Завершить Amanu"), () => _ = App.QuitAsync()));

        icon = new System.Windows.Forms.NotifyIcon { Icon = idleIcon, Text = "Amanu", Visible = runtime.Settings.TrayIcon };
        icon.MouseUp += (_, args) =>
        {
            if (args.Button == System.Windows.Forms.MouseButtons.Left) window.Dispatcher.Invoke(window.Reveal);
            else if (args.Button == System.Windows.Forms.MouseButtons.Right) window.Dispatcher.Invoke(OpenMenu);
        };
        icon.BalloonTipClicked += (_, _) => window.Dispatcher.Invoke(App.ShowRecordings);

        runtime.StateChanged += OnChanged;
        runtime.SettingsChanged += OnChanged;
        runtime.NotificationRequested += OnNotification;
        clock.Tick += (_, _) => { if (runtime.State.IsRecording) Refresh(); };
        clock.Start();
        Refresh();
    }

    private MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    private void OnChanged(object? sender, RecordingState e) => OnChanged(sender, EventArgs.Empty);

    private void OnChanged(object? sender, EventArgs e) => System.Windows.Application.Current.Dispatcher.InvokeAsync(Refresh);

    private void OnNotification(object? sender, (string Title, string Message, NotificationKind Kind) notification) =>
        System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
        {
            if (!icon.Visible) return;
            // One balloon at a time: a new one replaces the last rather than stacking.
            icon.BalloonTipTitle = notification.Title;
            icon.BalloonTipText = notification.Message.Length > 250 ? notification.Message[..250] + "…" : notification.Message;
            icon.BalloonTipIcon = notification.Kind switch
            {
                NotificationKind.Error => System.Windows.Forms.ToolTipIcon.Error,
                NotificationKind.Warning => System.Windows.Forms.ToolTipIcon.Warning,
                _ => System.Windows.Forms.ToolTipIcon.Info,
            };
            icon.ShowBalloonTip(6_000);
        });

    private void OpenMenu()
    {
        Refresh();
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;
        // Windows closes a popup on an outside click only when it is in the
        // foreground, and a menu opened from the tray is not until it is told.
        if (PresentationSource.FromVisual(menu) is HwndSource source) SetForegroundWindow(source.Handle);
    }

    private void Refresh()
    {
        var state = runtime.State;
        var elapsed = state.StartedAt is { } started ? DateTimeOffset.Now - started : TimeSpan.Zero;
        var display = RecordingDisplay.From(state, elapsed);
        var problem = runtime.ConfigProblems.FirstOrDefault()?.Headline;
        stateItem.Header = state.IsPaused ? $"❙❙ {display.Heading} · {display.Elapsed}"
            : state.IsRecording ? $"● {display.Heading} · {display.Elapsed}"
            : problem ?? display.Heading;
        recordItem.Header = display.RecordAction;
        pauseItem.Header = display.PauseAction;
        pauseItem.IsEnabled = display.CanPause;
        autoRecordItem.IsChecked = runtime.Settings.AutoRecord.Enabled;
        icon.Visible = runtime.Settings.TrayIcon;
        icon.Icon = state.IsPaused ? pausedIcon : state.IsRecording ? recordingIcon : idleIcon;
        var tooltip = state.IsRecording ? $"Amanu — {display.Heading} · {display.Elapsed}" : $"Amanu — {display.Heading}";
        icon.Text = tooltip.Length > 63 ? tooltip[..63] : tooltip;
    }

    public void Dispose()
    {
        clock.Stop();
        runtime.StateChanged -= OnChanged;
        runtime.SettingsChanged -= OnChanged;
        runtime.NotificationRequested -= OnNotification;
        icon.Visible = false;
        icon.Dispose();
        idleIcon.Dispose();
        recordingIcon.Dispose();
        pausedIcon.Dispose();
    }

    private static Icon LoadIcon()
    {
        var extracted = Environment.ProcessPath is { } path ? Icon.ExtractAssociatedIcon(path) : null;
        var result = (Icon)(extracted ?? SystemIcons.Application).Clone();
        extracted?.Dispose();
        return result;
    }

    /// <summary>The icon with a dot in its corner — red while recording, amber while paused.</summary>
    private static Icon Badge(Icon source, Color color)
    {
        using var bitmap = source.ToBitmap();
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var diameter = Math.Max(7, bitmap.Width / 2);
            var left = bitmap.Width - diameter;
            var top = bitmap.Height - diameter;
            graphics.FillEllipse(Brushes.White, left - 1, top - 1, diameter + 2, diameter + 2);
            using var brush = new SolidBrush(color);
            graphics.FillEllipse(brush, left, top, diameter, diameter);
        }
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint handle);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint handle);
}
