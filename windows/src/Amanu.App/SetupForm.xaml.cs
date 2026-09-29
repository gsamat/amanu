using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Amanu.Core.Configuration;
using RadioButton = System.Windows.Controls.RadioButton;
using UserControl = System.Windows.Controls.UserControl;

namespace Amanu.App;

/// <summary>The same macOS-inspired setup choices used in first run and Settings.</summary>
public partial class SetupForm : UserControl
{
    private AmanuRuntime? runtime;
    private bool loading;
    private bool syncingOpenAiKey;

    public SetupForm()
    {
        InitializeComponent();
        Loaded += (_, _) => AttachProgress();
        Unloaded += (_, _) => runtime?.DownloadProgressChanged -= DownloadProgressChanged;
    }

    public void SetAutoRecord(bool enabled) => AutoRecordSwitch.IsChecked = enabled;
    public void SetStartup(bool enabled) => StartupSwitch.IsChecked = enabled;

    public void LoadFrom(AmanuRuntime source)
    {
        if (runtime is not null) runtime.DownloadProgressChanged -= DownloadProgressChanged;
        runtime = source;
        if (IsLoaded) AttachProgress();
        loading = true;
        var settings = source.Settings;
        StartupSwitch.IsChecked = settings.StartAtLogin;
        AutoRecordSwitch.IsChecked = settings.AutoRecord.Enabled;
        AnalyticsSwitch.IsChecked = settings.Analytics;
        KeepAudioSwitch.IsChecked = settings.KeepAudio;
        LiveSwitch.IsChecked = settings.LiveTranscription.Enabled;
        TraySwitch.IsChecked = settings.TrayIcon;
        TaskbarSwitch.IsChecked = settings.TaskbarIcon;
        NamesSwitch.IsChecked = settings.SpeakerNames.Enabled;
        SummarySwitch.IsChecked = settings.Summary.Enabled;
        var choice = SetupChoice.FromSettings(settings.Transcription.Enabled, settings.Transcription.Engine);
        CloudSwitch.IsChecked = choice.Cloud;
        LocalSwitch.IsChecked = choice.Local;
        Select(CloudCards, settings.Transcription.Cloud, AssemblyCard);
        Select(LocalCards, settings.Transcription.LocalEngine, ParakeetCard);
        SelectLanguage(settings.Transcription.Language);
        Select(SummaryCards,
            settings.Summary.Backend is "openai" or "anthropic" ? "key" : settings.Summary.Backend,
            SummaryAutoCard);
        SummaryProviderCombo.SelectedIndex = settings.Summary.Backend == "anthropic" ? 1 : 0;
        AssemblyKeyBox.Password = source.GetSecret("assemblyai") ?? "";
        OpenAiKeyBox.Password = source.GetSecret("openai") ?? "";
        SummaryOpenAiKeyBox.Password = OpenAiKeyBox.Password;
        SummaryAnthropicKeyBox.Password = source.GetSecret("anthropic") ?? "";
        OllamaUrlText.Text = settings.Summary.OllamaUrl;
        OllamaModelText.Text = settings.Summary.OllamaModel;
        RecordingsPath.Text = settings.RecordingsDirectory;
        loading = false;
        RefreshChoices();
        RefreshModelStatus();
    }

    public void Save()
    {
        if (runtime is null) throw new InvalidOperationException("Форма настройки не загружена.");
        var settings = runtime.Settings;
        var mode = SetupChoice.FromSwitches(CloudSwitch.IsChecked == true, LocalSwitch.IsChecked == true);
        settings.Transcription.Enabled = mode.Enabled;
        settings.Transcription.Engine = mode.Engine;
        settings.Transcription.Cloud = Selected(CloudCards, "assemblyai");
        settings.Transcription.LocalEngine = Selected(LocalCards, "parakeet");
        settings.Transcription.Language = (LanguageCombo.SelectedItem as ComboBoxItem)?.Tag as string;
        if (settings.Transcription.Language == "") settings.Transcription.Language = null;
        settings.RecordingsDirectory = RecordingsPath.Text.Trim();
        settings.KeepAudio = KeepAudioSwitch.IsChecked == true;
        settings.LiveTranscription.Enabled = LiveSwitch.IsChecked == true;
        settings.SpeakerNames.Enabled = NamesSwitch.IsChecked == true;
        settings.Summary.Enabled = SummarySwitch.IsChecked == true;
        settings.Summary.Backend = SummaryAutoCard.IsChecked == true ? "auto"
            : SummaryOllamaCard.IsChecked == true ? "ollama"
            : (SummaryProviderCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "openai";
        settings.Summary.OllamaUrl = OllamaUrlText.Text.Trim();
        settings.Summary.OllamaModel = OllamaModelText.Text.Trim();
        settings.Analytics = AnalyticsSwitch.IsChecked == true;
        settings.TrayIcon = TraySwitch.IsChecked == true;
        settings.TaskbarIcon = TaskbarSwitch.IsChecked == true;
        if (!settings.TrayIcon && !settings.TaskbarIcon)
        {
            settings.TrayIcon = true;
            TraySwitch.IsChecked = true;
        }
        if (settings.AutoRecord.Enabled != (AutoRecordSwitch.IsChecked == true))
            runtime.SetAutoRecord(AutoRecordSwitch.IsChecked == true);
        if (settings.StartAtLogin != (StartupSwitch.IsChecked == true))
            runtime.SetStartAtLogin(StartupSwitch.IsChecked == true);
        runtime.SetSecret("assemblyai", Empty(AssemblyKeyBox.Password));
        runtime.SetSecret("openai", Empty(OpenAiKeyBox.Password));
        runtime.SetSecret("anthropic", Empty(SummaryAnthropicKeyBox.Password));
        runtime.SaveSettings();
    }

    private RadioButton[] CloudCards => [AssemblyCard, OpenAiCard];
    private RadioButton[] LocalCards => [ParakeetCard, WhisperCard, GigaAmCard];
    private RadioButton[] SummaryCards => [SummaryAutoCard, SummaryKeyCard, SummaryOllamaCard];

    private static string? Empty(string value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private void AttachProgress()
    {
        if (runtime is null) return;
        runtime.DownloadProgressChanged -= DownloadProgressChanged;
        runtime.DownloadProgressChanged += DownloadProgressChanged;
    }
    private static string Selected(IEnumerable<RadioButton> cards, string fallback) =>
        cards.FirstOrDefault(card => card.IsChecked == true)?.Tag as string ?? fallback;
    private static void Select(IEnumerable<RadioButton> cards, string value, RadioButton fallback)
    {
        var selected = cards.FirstOrDefault(card => card.Tag as string == value) ?? fallback;
        selected.IsChecked = true;
    }

    private void SelectLanguage(string? language)
    {
        var item = LanguageCombo.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(candidate => (candidate.Tag as string ?? "") == (language ?? ""));
        if (item is null && !string.IsNullOrWhiteSpace(language))
        {
            item = new ComboBoxItem { Content = language, Tag = language };
            LanguageCombo.Items.Add(item);
        }
        LanguageCombo.SelectedItem = item ?? LanguageCombo.Items[0];
    }

    private void CloudProvider_Checked(object sender, RoutedEventArgs e)
    {
        if (CloudKeySection is not null) RefreshChoices();
    }

    private void LocalModel_Checked(object sender, RoutedEventArgs e)
    {
        if (ModelStatus is not null && !loading) RefreshModelStatus();
    }

    private void SummaryBackend_Checked(object sender, RoutedEventArgs e)
    {
        if (SummaryKeyOptions is not null) RefreshChoices();
    }

    private void SummaryProvider_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SummaryOpenAiKeyBox is not null) RefreshChoices();
    }

    private void RefreshChoices()
    {
        var openai = OpenAiCard.IsChecked == true;
        AssemblyKeyBox.Visibility = openai ? Visibility.Collapsed : Visibility.Visible;
        OpenAiKeyBox.Visibility = openai ? Visibility.Visible : Visibility.Collapsed;
        CloudKeyLabel.Text = openai ? "OpenAI API-ключ" : "AssemblyAI API-ключ";
        SummaryKeyOptions.Visibility = SummaryKeyCard.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        OllamaOptions.Visibility = SummaryOllamaCard.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        var anthropic = (SummaryProviderCombo.SelectedItem as ComboBoxItem)?.Tag as string == "anthropic";
        SummaryOpenAiKeyBox.Visibility = anthropic ? Visibility.Collapsed : Visibility.Visible;
        SummaryAnthropicKeyBox.Visibility = anthropic ? Visibility.Visible : Visibility.Collapsed;
        AssemblyStatus.Text = string.IsNullOrWhiteSpace(AssemblyKeyBox.Password) ? "Нужен ключ" : "Ключ указан";
        OpenAiStatus.Text = string.IsNullOrWhiteSpace(OpenAiKeyBox.Password) ? "Нужен ключ" : "Ключ указан";
    }

    private void KeyBox_PasswordChanged(object sender, RoutedEventArgs e)
    {
        if (loading) return;
        if (!syncingOpenAiKey && (ReferenceEquals(sender, OpenAiKeyBox) || ReferenceEquals(sender, SummaryOpenAiKeyBox)))
        {
            syncingOpenAiKey = true;
            if (ReferenceEquals(sender, OpenAiKeyBox)) SummaryOpenAiKeyBox.Password = OpenAiKeyBox.Password;
            else OpenAiKeyBox.Password = SummaryOpenAiKeyBox.Password;
            syncingOpenAiKey = false;
        }
        if (CloudKeySection is not null) RefreshChoices();
    }

    private void RefreshModelStatus()
    {
        if (runtime is null) return;
        foreach (var (card, label) in new[]
        {
            (ParakeetCard, ParakeetStatus), (WhisperCard, WhisperStatus), (GigaAmCard, GigaAmStatus),
        })
        {
            var ready = runtime.IsLocalModelReady((string)card.Tag);
            label.Text = ready ? "Скачана" : "Не скачана";
            label.SetResourceReference(TextBlock.ForegroundProperty, ready ? "GoodStatus" : "MutedText");
        }
        ModelStatus.Text = runtime.IsLocalModelReady(Selected(LocalCards, "parakeet"))
            ? "Модель готова" : "Нужно скачать модель";
    }

    public async Task DownloadSelectedModelAsync()
    {
        if (runtime is null) return;
        var model = Selected(LocalCards, "parakeet");
        DownloadModelButton.IsEnabled = false;
        ModelProgress.Value = 0;
        ModelStatus.Text = "Скачиваю и проверяю модель…";
        try
        {
            await runtime.EnsureLocalModelAsync(model);
            RefreshModelStatus();
        }
        catch (Exception exception)
        {
            ModelStatus.Text = exception.Message;
            System.Windows.MessageBox.Show(exception.Message, "Не удалось скачать модель",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            DownloadModelButton.IsEnabled = true;
        }
    }

    private async void DownloadModelButton_Click(object sender, RoutedEventArgs e) =>
        await DownloadSelectedModelAsync();

    private void DownloadProgressChanged(object? sender, DownloadProgress progress) => Dispatcher.Invoke(() =>
    {
        ModelProgress.Value = progress.Percentage;
        ModelStatus.Text = $"{progress.Item}: {progress.Percentage}%";
    });

    private void PrivacyButton_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    private void ChooseFolderButton_Click(object sender, RoutedEventArgs e)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog { InitialDirectory = RecordingsPath.Text };
        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) RecordingsPath.Text = dialog.SelectedPath;
    }
}
