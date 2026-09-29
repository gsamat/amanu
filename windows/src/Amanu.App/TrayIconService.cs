using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using Amanu.Core.Recording;

namespace Amanu.App;

public sealed class TrayIconService : IDisposable
{
    private readonly NotifyIcon icon;
    private readonly Icon idleIcon;
    private readonly Icon recordingIcon;
    private readonly Icon pausedIcon;
    private readonly ToolStripMenuItem recordItem;
    private readonly ToolStripMenuItem pauseItem;
    private readonly AmanuRuntime runtime;
    private readonly EventHandler<RecordingState> stateChanged;

    public TrayIconService(CompactWindow window, AmanuRuntime runtime, bool visible)
    {
        this.runtime = runtime;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Открыть Amanu", null, (_, _) => window.Dispatcher.Invoke(window.ShowFromTray));
        recordItem = new ToolStripMenuItem("Начать запись", null, async (_, _) =>
            await (await window.Dispatcher.InvokeAsync(window.ToggleRecordingAsync)));
        pauseItem = new ToolStripMenuItem("Пауза", null, async (_, _) =>
            await (await window.Dispatcher.InvokeAsync(() => window.RuntimeTogglePauseAsync())));
        menu.Items.Add(recordItem);
        menu.Items.Add(pauseItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Записи…", null, (_, _) => window.Dispatcher.Invoke(window.ShowRecordingsFromTray));
        menu.Items.Add("Настройки…", null, (_, _) => window.Dispatcher.Invoke(window.ShowSettingsFromTray));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Завершить Amanu", null, async (_, _) =>
            await (await window.Dispatcher.InvokeAsync(window.QuitAsync)));

        var extracted = Environment.ProcessPath is { } path ? Icon.ExtractAssociatedIcon(path) : null;
        idleIcon = (Icon)(extracted ?? SystemIcons.Application).Clone();
        extracted?.Dispose();
        recordingIcon = Badge(idleIcon, Color.IndianRed);
        pausedIcon = Badge(idleIcon, Color.DarkOrange);

        icon = new NotifyIcon
        {
            Icon = idleIcon,
            Text = "Amanu — не записывает",
            ContextMenuStrip = menu,
            Visible = visible,
        };
        icon.DoubleClick += (_, _) => window.Dispatcher.Invoke(window.ShowFromTray);
        stateChanged = (_, state) => window.Dispatcher.InvokeAsync(() => UpdateState(state));
        runtime.StateChanged += stateChanged;
        UpdateState(runtime.State);
    }

    public void SetVisible(bool visible) => icon.Visible = visible;

    public void ShowNotification(string title, string message, ToolTipIcon kind = ToolTipIcon.Info)
    {
        if (!icon.Visible) return;
        icon.BalloonTipTitle = title;
        icon.BalloonTipText = message;
        icon.BalloonTipIcon = kind;
        icon.ShowBalloonTip(5_000);
    }

    public void Dispose()
    {
        runtime.StateChanged -= stateChanged;
        icon.Visible = false;
        icon.ContextMenuStrip?.Dispose();
        icon.Dispose();
        idleIcon.Dispose();
        recordingIcon.Dispose();
        pausedIcon.Dispose();
    }

    private void UpdateState(RecordingState state)
    {
        var display = RecordingDisplay.From(state, TimeSpan.Zero);
        icon.Icon = state.IsPaused ? pausedIcon : state.IsRecording ? recordingIcon : idleIcon;
        icon.Text = $"Amanu — {display.Heading}";
        recordItem.Text = display.RecordAction;
        pauseItem.Text = display.PauseAction;
        pauseItem.Enabled = display.CanPause;
    }

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
}
