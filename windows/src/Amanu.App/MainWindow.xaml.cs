using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Amanu.Core.Processing;
using Amanu.Core.Recording;
using Microsoft.Win32;

namespace Amanu.App;

public partial class MainWindow : Window
{
    private readonly AmanuRuntime runtime;
    private readonly System.Windows.Threading.DispatcherTimer elapsedTimer;
    private bool allowClose;

    public MainWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        InitializeComponent();
        LoadSettingsIntoControls();
        RecoveryText.Text = runtime.RecoveredSessionCount == 0 ? "" : $"Восстановлено прерванных записей: {runtime.RecoveredSessionCount}.";
        runtime.StateChanged += Runtime_StateChanged;
        runtime.ProcessingStatusChanged += Runtime_ProcessingStatusChanged;
        runtime.SessionsChanged += (_, _) => Dispatcher.InvokeAsync(RefreshSessionsAsync);
        runtime.LiveTranscriptChanged += (_, text) => Dispatcher.Invoke(() =>
        {
            if (LiveTranscriptText.Text.Length > 0) LiveTranscriptText.AppendText(Environment.NewLine);
            LiveTranscriptText.AppendText(text);
            LiveTranscriptText.ScrollToEnd();
        });
        elapsedTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        elapsedTimer.Tick += (_, _) => Refresh(runtime.State);
        elapsedTimer.Start();
        Closing += MainWindow_Closing;
        Loaded += async (_, _) => await RefreshSessionsAsync();
        UpdateDiagnostics();
    }

    public void ShowFromTray() { Show(); WindowState = WindowState.Normal; Activate(); }

    public void ShowSection(int index)
    {
        MainTabs.SelectedIndex = index;
        if (index == 1) _ = RefreshSessionsAsync();
    }

    public async Task QuitAsync()
    {
        allowClose = true;
        await runtime.StopForExitAsync();
        System.Windows.Application.Current.Shutdown();
    }

    private async void RecordButton_Click(object sender, RoutedEventArgs e)
    {
        try { await ToggleRecordingAsync(); }
        catch (Exception exception) { ShowError(exception, "Amanu не смог начать запись"); }
    }

    public async Task ToggleRecordingAsync()
    {
        if (runtime.State.IsRecording) await runtime.StopManualAsync();
        else { LiveTranscriptText.Clear(); await runtime.StartManualAsync(); }
    }

    private async void PauseButton_Click(object sender, RoutedEventArgs e) => await runtime.TogglePauseAsync();

    public Task RuntimeTogglePauseAsync() => runtime.TogglePauseAsync();

    private void AutoRecordCheckBox_Click(object sender, RoutedEventArgs e)
    {
        var enabled = AutoRecordCheckBox.IsChecked == true;
        runtime.SetAutoRecord(enabled);
        SettingsForm.SetAutoRecord(enabled);
    }

    private void StartupCheckBox_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var enabled = StartupCheckBox.IsChecked == true;
            runtime.SetStartAtLogin(enabled);
            SettingsForm.SetStartup(enabled);
        }
        catch (Exception exception)
        {
            StartupCheckBox.IsChecked = !StartupCheckBox.IsChecked;
            ShowError(exception, "Не удалось изменить автозапуск");
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
        try { await runtime.ImportAsync(dialog.FileName); await RefreshSessionsAsync(); }
        catch (Exception exception) { ShowError(exception, "Не удалось импортировать файл"); }
    }

    private async void RefreshSessionsButton_Click(object sender, RoutedEventArgs e) => await RefreshSessionsAsync();

    private async Task RefreshSessionsAsync()
    {
        var selected = SelectedSession?.Directory;
        var sessions = await runtime.LoadSessionsAsync();
        SessionsGrid.ItemsSource = sessions;
        if (selected is not null) SessionsGrid.SelectedItem = sessions.FirstOrDefault(item => item.Directory == selected);
        UpdateDiagnostics(sessions.Count);
    }

    private async void SessionsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SelectedSession is not { } session) { SummaryText.Clear(); TranscriptText.Clear(); return; }
        SummaryText.Text = await ReadIfPresentAsync(Path.Combine(session.Directory, "summary.md"));
        TranscriptText.Text = await ReadIfPresentAsync(Path.Combine(session.Directory, "transcript.md"));
    }

    private void OpenSelectedSessionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedSession is { } session) { runtime.TrackArtifact("session_folder"); Open(session.Directory); }
    }

    private void PlayAudioButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedSession is not { } session) return;
        var audio = Directory.EnumerateFiles(session.Directory)
            .FirstOrDefault(path => new[] { ".m4a", ".wav", ".mp3", ".flac", ".ogg" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase));
        if (audio is not null) { runtime.TrackArtifact("session_folder"); Open(audio); }
    }

    private void RetranscribeButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedSession is { } session) runtime.RetryProcessing(session.Directory, retranscribe: true);
    }

    private void ReprocessButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedSession is { } session) runtime.RetryProcessing(session.Directory, retranscribe: false);
    }

    private async void SaveSpeakerButton_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedSession is not { } session || string.IsNullOrWhiteSpace(SpeakerLabelText.Text) || string.IsNullOrWhiteSpace(SpeakerNameText.Text)) return;
        try
        {
            await runtime.SetSpeakerNameAsync(session.Directory, SpeakerLabelText.Text.Trim(), SpeakerNameText.Text.Trim());
            TranscriptText.Text = await ReadIfPresentAsync(Path.Combine(session.Directory, "transcript.md"));
        }
        catch (Exception exception) { ShowError(exception, "Не удалось сохранить имя спикера"); }
    }

    private void SaveSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        try { SaveSettingsFromControls(); }
        catch (Exception exception) { ShowError(exception, "Не удалось сохранить настройки"); }
    }

    private void SaveSettingsFromControls()
    {
        var settings = runtime.Settings;
        var oldDirectory = settings.RecordingsDirectory;
        SettingsForm.Save();
        settings.UserName = EmptyToNull(UserNameText.Text);
        settings.Transcription.OpenAiModel = OpenAiTranscriptionModelText.Text.Trim();
        settings.Transcription.EchoFilter = EchoFilterCheckBox.IsChecked == true;
        settings.Transcription.OfflineEchoCancellation = OfflineEchoCheckBox.IsChecked == true;
        settings.SpeakerNames.Backend = SelectedText(SpeakerBackendCombo);
        settings.SpeakerNames.Model = EmptyToNull(SpeakerModelText.Text);
        settings.Summary.OpenAiModel = SummaryOpenAiModelText.Text.Trim();
        settings.Summary.AnthropicModel = SummaryAnthropicModelText.Text.Trim();
        settings.Summary.Language = EmptyToNull(SummaryLanguageText.Text);
        settings.Summary.Template = SummaryTemplateText.Text == SummaryTemplate.Default ? null : EmptyToNull(SummaryTemplateText.Text);
        settings.AutoRecord.MicrophoneActivity = MicrophoneActivityCheckBox.IsChecked == true;
        settings.AutoRecord.StartDelaySeconds = PositiveInt(StartDelayText.Text, settings.AutoRecord.StartDelaySeconds);
        settings.AutoRecord.StopDelaySeconds = PositiveInt(StopDelayText.Text, settings.AutoRecord.StopDelaySeconds);
        settings.AutoRecord.MinimumDurationSeconds = PositiveInt(MinimumDurationText.Text, settings.AutoRecord.MinimumDurationSeconds);
        settings.AutoRecord.SilenceStopMinutes = PositiveInt(SilenceStopText.Text, settings.AutoRecord.SilenceStopMinutes);
        settings.AutoRecord.MaximumDurationMinutes = PositiveInt(MaximumDurationText.Text, settings.AutoRecord.MaximumDurationMinutes);
        settings.AutoRecord.CallProcesses = Lines(CallAppsText.Text);
        settings.AutoRecord.IgnoreProcesses = Lines(IgnoreAppsText.Text);
        settings.OnStop = string.IsNullOrWhiteSpace(HookExecutableText.Text) ? null : new Amanu.Core.Configuration.CommandHook
        {
            Executable = HookExecutableText.Text.Trim(), Arguments = Lines(HookArgumentsText.Text),
        };
        runtime.SaveSettings();
        ShowInTaskbar = settings.TaskbarIcon;
        AutoRecordCheckBox.IsChecked = settings.AutoRecord.Enabled;
        StartupCheckBox.IsChecked = settings.StartAtLogin;
        UpdateDiagnostics();
        SettingsStatusText.Text = oldDirectory == settings.RecordingsDirectory
            ? "Настройки сохранены. Изменения автодетекта применятся после перезапуска Amanu."
            : "Настройки сохранены. Новая папка и автодетект начнут использоваться после перезапуска Amanu.";
    }

    private void LoadSettingsIntoControls()
    {
        var settings = runtime.Settings;
        SettingsForm.LoadFrom(runtime);
        AutoRecordCheckBox.IsChecked = settings.AutoRecord.Enabled;
        StartupCheckBox.IsChecked = settings.StartAtLogin;
        UserNameText.Text = settings.UserName ?? "";
        OpenAiTranscriptionModelText.Text = settings.Transcription.OpenAiModel;
        EchoFilterCheckBox.IsChecked = settings.Transcription.EchoFilter;
        OfflineEchoCheckBox.IsChecked = settings.Transcription.OfflineEchoCancellation;
        Select(SpeakerBackendCombo, settings.SpeakerNames.Backend);
        SpeakerModelText.Text = settings.SpeakerNames.Model ?? "";
        SummaryOpenAiModelText.Text = settings.Summary.OpenAiModel;
        SummaryAnthropicModelText.Text = settings.Summary.AnthropicModel;
        SummaryLanguageText.Text = settings.Summary.Language ?? "";
        SummaryTemplateText.Text = settings.Summary.Template ?? SummaryTemplate.Default;
        MicrophoneActivityCheckBox.IsChecked = settings.AutoRecord.MicrophoneActivity;
        StartDelayText.Text = settings.AutoRecord.StartDelaySeconds.ToString();
        StopDelayText.Text = settings.AutoRecord.StopDelaySeconds.ToString();
        MinimumDurationText.Text = settings.AutoRecord.MinimumDurationSeconds.ToString();
        SilenceStopText.Text = settings.AutoRecord.SilenceStopMinutes.ToString();
        MaximumDurationText.Text = settings.AutoRecord.MaximumDurationMinutes.ToString();
        CallAppsText.Text = string.Join(Environment.NewLine, settings.AutoRecord.CallProcesses);
        IgnoreAppsText.Text = string.Join(Environment.NewLine, settings.AutoRecord.IgnoreProcesses);
        HookExecutableText.Text = settings.OnStop?.Executable ?? "";
        HookArgumentsText.Text = string.Join(Environment.NewLine, settings.OnStop?.Arguments ?? []);
        ShowInTaskbar = settings.TaskbarIcon;
    }

    private void Runtime_StateChanged(object? sender, RecordingState state) => Dispatcher.Invoke(() => Refresh(state));

    private void Runtime_ProcessingStatusChanged(object? sender, ProcessingStatus status) => Dispatcher.Invoke(() =>
    {
        ProcessingText.Text = status.Message;
        ProcessingProgress.Visibility = status.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ProcessingProgress.IsIndeterminate = status.IsBusy;
    });

    private void Refresh(RecordingState state)
    {
        StatusText.Text = state.IsRecording ? "Запись идёт" : "Готово";
        DetailText.Text = state.Status;
        RecordButton.Content = state.IsRecording ? "Остановить запись" : "Начать запись";
        PauseButton.IsEnabled = state.IsRecording;
        PauseButton.Content = state.IsPaused ? "Продолжить" : "Пауза";
        ElapsedText.Text = state.StartedAt is { } started ? (DateTimeOffset.Now - started).ToString(@"hh\:mm\:ss") : "";
    }

    private void UpdateDiagnostics(int? count = null)
    {
        var local = runtime.IsLocalModelReady(runtime.Settings.Transcription.LocalEngine) ? "ready" : "not installed";
        DiagnosticsText.Text = $"Platform: Windows 11 x64\nConfig: {runtime.ConfigPath}\nRecordings: {runtime.Settings.RecordingsDirectory}\nSessions: {(count?.ToString() ?? "refreshing")}\nLocal {runtime.Settings.Transcription.LocalEngine}: {local}\nAssemblyAI key: {Configured("assemblyai")}\nOpenAI key: {Configured("openai")}\nAnthropic key: {Configured("anthropic")}\nAuto-start: {(runtime.Settings.StartAtLogin ? "on" : "off")}";
    }

    private string Configured(string name) => string.IsNullOrWhiteSpace(runtime.GetSecret(name)) ? "missing" : "configured";
    private SessionListItem? SelectedSession => SessionsGrid.SelectedItem as SessionListItem;
    private void OpenRecordingsButton_Click(object sender, RoutedEventArgs e) { runtime.TrackArtifact("recordings_root"); Open(runtime.Settings.RecordingsDirectory); }
    private void OpenConfigButtonButton_Click(object sender, RoutedEventArgs e) => Open(runtime.ConfigPath);
    private void PrivacyButton_Click(object sender, RoutedEventArgs e) => Open("ms-settings:privacy-microphone");
    private static void Open(string target) => Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
    private static async Task<string> ReadIfPresentAsync(string path) => File.Exists(path) ? await File.ReadAllTextAsync(path) : "";
    private static string? EmptyToNull(string value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    private static int PositiveInt(string value, int fallback) => int.TryParse(value, out var parsed) && parsed >= 0 ? parsed : fallback;
    private static List<string> Lines(string value) => value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    private static string SelectedText(System.Windows.Controls.ComboBox combo) => (combo.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "auto";
    private static void Select(System.Windows.Controls.ComboBox combo, string value) => combo.SelectedItem = combo.Items.Cast<ComboBoxItem>().FirstOrDefault(item => string.Equals(item.Content?.ToString(), value, StringComparison.OrdinalIgnoreCase)) ?? combo.Items[0];
    private static void ShowError(Exception exception, string title) => System.Windows.MessageBox.Show(exception.Message, title, MessageBoxButton.OK, MessageBoxImage.Error);

    private void MainTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ReferenceEquals(e.Source, MainTabs)) return;
        if (MainTabs.SelectedIndex == 1) runtime.TrackArtifact("recordings_window");
        if (MainTabs.SelectedIndex == 2) runtime.TrackSettingsOpened();
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (allowClose) return;
        if (!runtime.Settings.TrayIcon) { allowClose = true; return; }
        e.Cancel = true;
        Hide();
    }
}
