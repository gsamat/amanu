using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Amanu.Core.Processing;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;
using static Amanu.Core.Localization.Localized;
using CheckBox = System.Windows.Controls.CheckBox;
using DataFormats = System.Windows.DataFormats;
using DragDropEffects = System.Windows.DragDropEffects;
using DragEventArgs = System.Windows.DragEventArgs;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;

namespace Amanu.App;

/// <summary>
/// A small ordinary window with the same controls as the tray menu. It answers one
/// question — am I being recorded — and borrows height only while a live
/// transcript needs it. Closing it hides it: the recorder keeps running, and the
/// tray icon or opening Amanu again brings it back.
/// </summary>
internal sealed class StatusWindow : Window
{
    private readonly AmanuRuntime runtime;
    private readonly Ellipse dot = new() { Width = 10, Height = 10, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock state = new() { FontSize = 16, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock processingLine = Ui.Status();
    private readonly TextBlock problemLine = Ui.Status("", Ui.Caution);
    private readonly System.Windows.Controls.Button record;
    private readonly System.Windows.Controls.Button pause;
    private readonly CheckBox autoRecord = new ClickCheckBox { Content = T("Record meetings automatically", "Записывать встречи автоматически") };
    private readonly TextBlock decision = Ui.Status();
    private readonly CheckBox live = new ClickCheckBox { Content = T("Live transcript", "Расшифровка на лету") };
    private readonly TextBlock liveStatus = Ui.Status();
    private readonly Grid livePanel = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBlock livePlaceholder = new()
    {
        Margin = new Thickness(16),
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };
    private readonly TextBlock liveReveal = new() { FontSize = 12, Visibility = Visibility.Collapsed };
    private readonly RichTextBox liveText = new()
    {
        IsReadOnly = true,
        Height = 240,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        BorderThickness = new Thickness(1),
    };
    private readonly DispatcherTimer clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly DispatcherTimer processingFade = new() { Interval = TimeSpan.FromSeconds(8) };
    private bool operationPending;
    private bool wasRecording;
    private bool? wasLiveEnabled;
    private bool allowClose;
    private readonly Dictionary<long, (Paragraph Paragraph, Run Text)> liveParagraphs = [];

    public StatusWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        Title = "Amanu";
#if DEBUG
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("AMANU_TEST_DATA")))
            Title = "Amanu — Live transcript test";
#endif
        Width = 360;
        SizeToContent = SizeToContent.Height;
        MinWidth = 320;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.WindowIcon;
        AllowDrop = true;

        record = Ui.Button(T("Start recording", "Начать запись"), () => _ = ToggleRecordingAsync(), accent: true);
        pause = Ui.Button(T("Pause", "Пауза"), () => _ = TogglePauseAsync());
        // A FlowDocument keeps its own serif default rather than the window's font.
        liveText.Document = new FlowDocument { PagePadding = new Thickness(6), FontFamily = SystemFonts.MessageFontFamily, FontSize = 13 };
        Ui.KeepOnScreen(this);

        var stack = new StackPanel { Margin = new Thickness(20, 16, 20, 18) };
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        header.Children.Add(dot);
        header.Children.Add(state);
        stack.Children.Add(header);
        processingLine.Margin = new Thickness(20, 4, 0, 0);
        stack.Children.Add(processingLine);
        problemLine.Margin = new Thickness(20, 4, 0, 0);
        stack.Children.Add(problemLine);

        var buttons = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        buttons.ColumnDefinitions.Add(new ColumnDefinition());
        record.HorizontalAlignment = HorizontalAlignment.Stretch;
        pause.HorizontalAlignment = HorizontalAlignment.Stretch;
        record.Margin = new Thickness(0, 0, 4, 0);
        pause.Margin = new Thickness(4, 0, 0, 0);
        Grid.SetColumn(pause, 1);
        buttons.Children.Add(record);
        buttons.Children.Add(pause);
        stack.Children.Add(buttons);

        autoRecord.Margin = new Thickness(0, 14, 0, 0);
        stack.Children.Add(autoRecord);
        decision.Margin = new Thickness(28, 0, 0, 0);
        stack.Children.Add(decision);

        foreach (var (text, action) in new (string, Action)[]
        {
            (T("Import…", "Импортировать…"), () => _ = App.ImportAsync(this)),
            (T("Open recordings folder", "Открыть папку записей"), () => { runtime.TrackArtifact("recordings_root"); AmanuRuntime.Open(runtime.Settings.RecordingsDirectory); }),
            (T("Manage recordings…", "Управление записями…"), App.ShowRecordings),
            (T("Settings…", "Настройки…"), () => App.ShowSettings(0)),
        })
        {
            var button = Ui.Button(text, action);
            button.HorizontalAlignment = HorizontalAlignment.Stretch;
            button.Margin = new Thickness(0, stack.Children.Count == 6 ? 14 : 6, 0, 0);
            stack.Children.Add(button);
        }

        live.Margin = new Thickness(0, 14, 0, 0);
        stack.Children.Add(live);
        liveStatus.TextWrapping = TextWrapping.Wrap;
        liveStatus.Margin = new Thickness(0, 4, 0, 0);
        stack.Children.Add(liveStatus);
        liveReveal.Inlines.Add(new Hyperlink(new Run(T("Show the live transcript", "Показать расшифровку на лету"))));
        ((Hyperlink)liveReveal.Inlines.FirstInline).Click += (_, _) => ShowLive(true);
        stack.Children.Add(liveReveal);
        livePanel.Children.Add(liveText);
        livePanel.Children.Add(livePlaceholder);
        stack.Children.Add(livePanel);
        Content = stack;

        autoRecord.Click += (_, _) =>
        {
            if (!Ui.TryUpdate(this, () => runtime.SetAutoRecord(autoRecord.IsChecked == true))) Refresh();
        };
        live.Click += (_, _) =>
        {
            Ui.TryUpdate(this, () => runtime.Update(settings => settings.LiveTranscription.Enabled = live.IsChecked == true));
            Refresh();
        };
        runtime.StateChanged += (_, _) => Dispatcher.InvokeAsync(Refresh);
        runtime.SettingsChanged += (_, _) => Dispatcher.InvokeAsync(Refresh);
        runtime.ProcessingStatusChanged += (_, status) => Dispatcher.InvokeAsync(() => ShowProcessing(status));
        runtime.LiveLineReady += (_, line) => Dispatcher.InvokeAsync(() => AppendLive(line));
        runtime.LiveStatusChanged += (_, _) => Dispatcher.InvokeAsync(RefreshLivePlaceholder);
        // With no tray icon there is no balloon to show, so what it would have
        // said is said here instead.
        runtime.NotificationRequested += (_, notice) => Dispatcher.InvokeAsync(() =>
        {
            if (runtime.Settings.TrayIcon || notice.Kind == NotificationKind.Information) return;
            processingFade.Stop();
            processingLine.Visibility = Visibility.Visible;
            processingLine.Text = $"{notice.Title}: {notice.Message}";
            processingLine.SetResourceReference(TextBlock.ForegroundProperty, notice.Kind == NotificationKind.Error ? Ui.Critical : Ui.Caution);
        });
        clock.Tick += (_, _) => Refresh();
        clock.Start();
        processingFade.Tick += (_, _) =>
        {
            processingFade.Stop();
            processingLine.Visibility = Visibility.Collapsed;
        };
        Drop += OnDrop;
        DragOver += (_, args) =>
        {
            args.Effects = args.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
            args.Handled = true;
        };
        processingLine.Visibility = Visibility.Collapsed;
        Refresh();
    }

    public void Reveal()
    {
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    public void AllowClose() => allowClose = true;

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (!allowClose)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    public async Task ToggleRecordingAsync()
    {
        if (operationPending) return;
        operationPending = true;
        Refresh();
        try
        {
            if (runtime.State.IsRecording) await runtime.StopManualAsync();
            else
            {
                liveText.Document.Blocks.Clear();
                liveParagraphs.Clear();
                ShowLive(runtime.Settings.LiveTranscription.Enabled);
                await runtime.StartManualAsync();
            }
        }
        catch (Exception exception)
        {
            Ui.ShowError(IsVisible ? this : null, T("Couldn’t change the recording", "Не удалось изменить запись"), exception.Message);
        }
        finally
        {
            operationPending = false;
            Refresh();
        }
    }

    public async Task TogglePauseAsync()
    {
        if (!runtime.State.IsRecording || operationPending) return;
        try { await runtime.TogglePauseAsync(); }
        catch (Exception exception) { Ui.ShowError(this, T("Couldn’t pause", "Не удалось поставить на паузу"), exception.Message); }
        finally { Refresh(); }
    }

    private void Refresh()
    {
        var current = runtime.State;
        var settings = runtime.Settings;
        var elapsed = current.StartedAt is { } started ? DateTimeOffset.Now - started : TimeSpan.Zero;
        var display = RecordingDisplay.From(current, elapsed);
        state.Text = current.IsRecording ? $"{display.Heading} · {display.Elapsed}" : display.Heading;
        var color = current.IsPaused ? Ui.Caution : current.IsRecording ? Ui.Critical : Ui.Tertiary;
        dot.SetResourceReference(Shape.FillProperty, color);
        state.SetResourceReference(TextBlock.ForegroundProperty, current.IsRecording ? color : Ui.Primary);
        record.Content = display.RecordAction;
        record.IsEnabled = !operationPending;
        pause.Content = display.PauseAction;
        pause.IsEnabled = display.CanPause && !operationPending;
        autoRecord.IsChecked = settings.AutoRecord.Enabled;
        decision.Text = current.IsRecording
            ? current.Trigger == SessionTrigger.Manual
                ? T("recording by hand · microphone and call audio", "запись вручную · микрофон и звук звонка")
                : T($"{current.ProcessFamily} holds the microphone", $"{current.ProcessFamily} держит микрофон")
            : settings.AutoRecord.Enabled ? runtime.AutoRecord.LastDecision : T("auto-record is off", "автозапись выключена");
        live.IsChecked = settings.LiveTranscription.Enabled;
        live.IsEnabled = settings.Transcription.Enabled;
        if (wasLiveEnabled != settings.LiveTranscription.Enabled)
        {
            wasLiveEnabled = settings.LiveTranscription.Enabled;
            ShowLive(settings.LiveTranscription.Enabled);
        }
        if (!wasRecording && current.IsRecording)
        {
            liveText.Document.Blocks.Clear();
            liveParagraphs.Clear();
            liveReveal.Visibility = Visibility.Collapsed;
            ShowLive(settings.LiveTranscription.Enabled);
        }
        var problems = runtime.ConfigProblems;
        problemLine.Text = problems.Count > 0 ? problems[0].Headline : "";
        problemLine.Visibility = problems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowInTaskbar = settings.TaskbarIcon;
        if (wasRecording && !current.IsRecording)
        {
            // A recording that stopped folds its transcript away, and leaves a way back to it.
            ShowLive(false);
            liveReveal.Visibility = liveText.Document.Blocks.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        wasRecording = current.IsRecording;
        RefreshLivePlaceholder();
    }

    private void ShowProcessing(ProcessingStatus status)
    {
        processingFade.Stop();
        processingLine.Visibility = Visibility.Visible;
        processingLine.Text = status.Stage switch
        {
            "queued" => T("waiting to be processed", "ждёт обработки"),
            "transcribing" or "speakers" or "summary" => status.Message.ToLower(Culture),
            "complete" => T("processed · see Recordings", "обработано · результат в «Записях»"),
            "failed" => T("couldn’t process: ", "не удалось обработать: ") + status.Message,
            "deferred" => T("waiting: ", "ждёт: ") + status.Message,
            _ => status.Message,
        };
        processingLine.SetResourceReference(TextBlock.ForegroundProperty, status.Stage == "failed" ? Ui.Critical : Ui.Secondary);
        if (status.Stage is "complete" or "deferred") processingFade.Start();
    }

    private void AppendLive(LiveLine line)
    {
        if (!liveParagraphs.TryGetValue(line.Id, out var existing))
        {
            var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, 6) };
            paragraph.Inlines.Add(new Run(SpeakerLabels.Display(line.Speaker) + "  ") { FontWeight = FontWeights.SemiBold });
            existing = (paragraph, new Run());
            paragraph.Inlines.Add(existing.Text);
            liveParagraphs[line.Id] = existing;
            liveText.Document.Blocks.Add(paragraph);
            if (liveParagraphs.Count > 200)
            {
                var first = liveParagraphs.First();
                liveText.Document.Blocks.Remove(first.Value.Paragraph);
                liveParagraphs.Remove(first.Key);
            }
        }
        existing.Text.Text = line.Text;
        RefreshLivePlaceholder();
        liveText.ScrollToEnd();
        // A final result may arrive after disabling live recognition. Keep the
        // text, but do not reopen a panel the user has just switched off.
        if (runtime.State.IsRecording && runtime.Settings.LiveTranscription.Enabled) ShowLive(true);
    }

    private void ShowLive(bool visible)
    {
        livePanel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (visible) liveReveal.Visibility = Visibility.Collapsed;
        RefreshLivePlaceholder();
    }

    private void RefreshLivePlaceholder()
    {
        var recognitionStatus = runtime.LiveStatus;
        var current = runtime.State;
        var enabled = runtime.Settings.LiveTranscription.Enabled;
        liveStatus.Text = enabled ? recognitionStatus : "";
        liveStatus.Visibility = string.IsNullOrWhiteSpace(liveStatus.Text) ? Visibility.Collapsed : Visibility.Visible;
        livePlaceholder.Visibility = liveParagraphs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        livePlaceholder.Text = !runtime.Settings.Transcription.Enabled
            ? T("Enable transcription in Settings to see live speech here.", "Включите расшифровку в настройках, чтобы видеть речь здесь.")
            : !current.IsRecording
                ? T("Start recording to see live speech here.", "Начните запись, чтобы видеть речь здесь.")
                : current.IsPaused
                    ? T("Recording paused.", "Запись на паузе.")
                    : !runtime.IsLocalModelReady("nemotron-live")
                        ? T("Download the live model in Settings.", "Скачайте модель лайва в настройках.")
                        : !string.IsNullOrWhiteSpace(recognitionStatus) && recognitionStatus != T("live", "в реальном времени")
                            ? recognitionStatus
                            : T("Waiting for speech…", "Ожидание речи…");
    }

    private async void OnDrop(object sender, DragEventArgs args)
    {
        if (args.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
        foreach (var file in files.Where(File.Exists))
        {
            try { await runtime.ImportAsync(file); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Ui.ShowError(this, T("Couldn’t import the file", "Не удалось импортировать файл"), exception.Message);
            }
        }
    }
}
