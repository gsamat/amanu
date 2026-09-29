using System.Windows;
using System.Windows.Media;
using Amanu.Core.Recording;
using Amanu.Core.Sessions;

namespace Amanu.App;

public partial class CompactWindow : Window
{
    private readonly AmanuRuntime runtime;
    private readonly System.Windows.Threading.DispatcherTimer elapsedTimer;
    private readonly System.Windows.Threading.DispatcherTimer processingDismissTimer;
    private MainWindow? workspace;
    private bool recordingOperationPending;
    private bool allowClose;
    private bool wasRecording;
    private double? heightBeforeTranscript;

    public CompactWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        InitializeComponent();
        if (ShowInTaskbar != runtime.Settings.TaskbarIcon)
            ShowInTaskbar = runtime.Settings.TaskbarIcon;
        AutoRecordCheckBox.IsChecked = runtime.Settings.AutoRecord.Enabled;
        LiveCheckBox.IsChecked = runtime.Settings.LiveTranscription.Enabled;
        runtime.StateChanged += (_, state) => Dispatcher.InvokeAsync(() => Refresh(state));
        runtime.ProcessingStatusChanged += (_, status) => Dispatcher.InvokeAsync(() => ShowProcessing(status));
        runtime.LiveTranscriptChanged += (_, text) => Dispatcher.InvokeAsync(() => AppendTranscript(text));
        elapsedTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        elapsedTimer.Tick += (_, _) => Refresh(runtime.State);
        elapsedTimer.Start();
        processingDismissTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        processingDismissTimer.Tick += (_, _) =>
        {
            processingDismissTimer.Stop();
            ProcessingPanel.Visibility = Visibility.Collapsed;
        };
        Activated += (_, _) => Refresh(runtime.State);
        Closing += CompactWindow_Closing;
        Refresh(runtime.State);
    }

    public void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    public void ShowRecordingsFromTray() => ShowWorkspace(1);
    public void ShowSettingsFromTray() => ShowWorkspace(2);

    public async Task ToggleRecordingAsync()
    {
        if (recordingOperationPending) return;
        recordingOperationPending = true;
        RecordButton.IsEnabled = false;
        try
        {
            if (runtime.State.IsRecording)
                await runtime.StopManualAsync();
            else
            {
                LiveTranscriptText.Clear();
                TranscriptToggleButton.Visibility = Visibility.Collapsed;
                HideTranscript();
                await runtime.StartManualAsync();
            }
        }
        catch (Exception exception)
        {
            ShowError(exception, "Не удалось изменить запись");
        }
        finally
        {
            recordingOperationPending = false;
            Refresh(runtime.State);
        }
    }

    public async Task RuntimeTogglePauseAsync()
    {
        if (!runtime.State.IsRecording || recordingOperationPending) return;
        PauseButton.IsEnabled = false;
        try { await runtime.TogglePauseAsync(); }
        catch (Exception exception) { ShowError(exception, "Не удалось изменить паузу"); }
        finally { Refresh(runtime.State); }
    }

    public async Task QuitAsync()
    {
        if (allowClose) return;
        try
        {
            await runtime.StopForExitAsync();
            allowClose = true;
            System.Windows.Application.Current.Shutdown();
        }
        catch (Exception exception) { ShowError(exception, "Не удалось завершить Amanu"); }
    }

    private async void RecordButton_Click(object sender, RoutedEventArgs e) => await ToggleRecordingAsync();
    private async void PauseButton_Click(object sender, RoutedEventArgs e) => await RuntimeTogglePauseAsync();

    private void AutoRecordCheckBox_Click(object sender, RoutedEventArgs e)
    {
        try { runtime.SetAutoRecord(AutoRecordCheckBox.IsChecked == true); }
        catch (Exception exception)
        {
            AutoRecordCheckBox.IsChecked = runtime.Settings.AutoRecord.Enabled;
            ShowError(exception, "Не удалось изменить автоматическую запись");
        }
        Refresh(runtime.State);
    }

    private void LiveCheckBox_Click(object sender, RoutedEventArgs e)
    {
        var previous = runtime.Settings.LiveTranscription.Enabled;
        try
        {
            runtime.Settings.LiveTranscription.Enabled = LiveCheckBox.IsChecked == true;
            runtime.SaveSettings();
        }
        catch (Exception exception)
        {
            runtime.Settings.LiveTranscription.Enabled = previous;
            LiveCheckBox.IsChecked = previous;
            ShowError(exception, "Не удалось изменить расшифровку на ходу");
        }
    }

    private async void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Импорт записи",
            Filter = "Аудио и видео|*.wav;*.m4a;*.mp3;*.flac;*.ogg;*.aac;*.mp4;*.mov;*.mkv;*.webm|Все файлы|*.*",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            await runtime.ImportAsync(dialog.FileName);
            ShowWorkspace(1);
        }
        catch (Exception exception) { ShowError(exception, "Не удалось импортировать файл"); }
    }

    private void RecordingsButton_Click(object sender, RoutedEventArgs e) => ShowWorkspace(1);
    private void SettingsButton_Click(object sender, RoutedEventArgs e) => ShowWorkspace(2);

    private void ShowWorkspace(int section)
    {
        if (workspace is null)
        {
            workspace = new MainWindow(runtime);
            workspace.Closed += (_, _) => workspace = null;
        }
        workspace.ShowSection(section);
        workspace.Show();
        workspace.WindowState = WindowState.Normal;
        workspace.Activate();
    }

    private void Refresh(RecordingState state)
    {
        var elapsed = state.StartedAt is { } start ? DateTimeOffset.Now - start : TimeSpan.Zero;
        var display = RecordingDisplay.From(state, elapsed);
        StateText.Text = display.Heading;
        ElapsedText.Text = display.Elapsed;
        RecordButton.Content = display.RecordAction;
        RecordButton.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, display.RecordAction);
        RecordButton.IsEnabled = !recordingOperationPending;
        PauseButton.Content = display.PauseAction;
        PauseButton.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, display.PauseAction);
        PauseButton.IsEnabled = display.CanPause && !recordingOperationPending;
        LiveCheckBox.IsEnabled = !state.IsRecording;
        LiveCheckBox.ToolTip = state.IsRecording ? "Изменить можно перед следующей записью" : null;
        AutoRecordCheckBox.IsChecked = runtime.Settings.AutoRecord.Enabled;
        LiveCheckBox.IsChecked = runtime.Settings.LiveTranscription.Enabled;
        if (ShowInTaskbar != runtime.Settings.TaskbarIcon)
            ShowInTaskbar = runtime.Settings.TaskbarIcon;
        DetailText.Text = state.IsPaused ? "Звук временно не сохраняется"
            : state.IsRecording ? state.Trigger == SessionTrigger.Manual
                ? "Запись вручную · микрофон и звук звонка"
                : "Автоматическая запись · микрофон и звук звонка"
            : runtime.Settings.AutoRecord.Enabled ? "Ожидаю звонок" : "Автоматическая запись выключена";
        StateDot.Fill = SystemParameters.HighContrast ? System.Windows.SystemColors.WindowTextBrush
            : state.IsPaused ? System.Windows.Media.Brushes.DarkOrange
            : state.IsRecording ? System.Windows.Media.Brushes.IndianRed
            : (System.Windows.Media.Brush)System.Windows.Application.Current.Resources["MutedText"];
        if (wasRecording && !state.IsRecording) HideTranscript();
        wasRecording = state.IsRecording;
    }

    private void ShowProcessing(ProcessingStatus status)
    {
        processingDismissTimer.Stop();
        ProcessingPanel.Visibility = Visibility.Visible;
        ProcessingText.Text = status.Stage switch
        {
            "queued" => "Запись поставлена в очередь обработки",
            "transcribing" => "Расшифровываю запись…",
            "speakers" => "Определяю участников…",
            "summary" => "Готовлю итог встречи…",
            "complete" => "Запись обработана · результат в «Записях»",
            "failed" => $"Не удалось обработать запись: {status.Message}",
            "deferred" => $"Обработка отложена: {status.Message}",
            _ => status.Message,
        };
        if (status.Stage == "complete") processingDismissTimer.Start();
    }

    private void AppendTranscript(string text)
    {
        if (LiveTranscriptText.Text.Length > 0) LiveTranscriptText.AppendText(Environment.NewLine);
        LiveTranscriptText.AppendText(text);
        LiveTranscriptText.ScrollToEnd();
        TranscriptToggleButton.Visibility = Visibility.Visible;
    }

    private void TranscriptToggleButton_Click(object sender, RoutedEventArgs e)
    {
        if (TranscriptPanel.Visibility == Visibility.Visible) HideTranscript();
        else
        {
            heightBeforeTranscript = Height;
            TranscriptPanel.Visibility = Visibility.Visible;
            TranscriptToggleButton.Content = "Скрыть расшифровку";
            Height = Math.Max(Height, Math.Min(540, SystemParameters.WorkArea.Height - 32));
            Top = Math.Max(SystemParameters.WorkArea.Top,
                Math.Min(Top, SystemParameters.WorkArea.Bottom - Height));
        }
    }

    private void HideTranscript()
    {
        TranscriptPanel.Visibility = Visibility.Collapsed;
        TranscriptToggleButton.Content = "Показать расшифровку";
        if (heightBeforeTranscript is { } height) Height = height;
        heightBeforeTranscript = null;
    }

    private async void CompactWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (allowClose) return;
        e.Cancel = true;
        if (runtime.Settings.TrayIcon) Hide();
        else await QuitAsync();
    }

    private void ShowError(Exception exception, string title) =>
        System.Windows.MessageBox.Show(this, exception.Message, title,
            MessageBoxButton.OK, MessageBoxImage.Error);
}
