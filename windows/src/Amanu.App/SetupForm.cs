using System.IO;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using static Amanu.Core.Localization.Localized;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;
using PasswordBox = System.Windows.Controls.PasswordBox;
using ProgressBar = System.Windows.Controls.ProgressBar;
using RadioButton = System.Windows.Controls.RadioButton;
using TextBox = System.Windows.Controls.TextBox;

namespace Amanu.App;

/// <summary>
/// Everything a new installation is asked, and the first tab of Settings: one
/// form in two places, so the two never drift into disagreeing about what Amanu
/// offers. Every control takes effect the moment it is changed — there is no
/// Save button, because a switch that does nothing until another button is found
/// is a switch that lies about the state it shows.
/// </summary>
/// <remarks>The sections, their order and their words follow the macOS setup form.</remarks>
internal sealed class SetupForm
{
    private readonly AmanuRuntime runtime;
    private readonly bool showsConfigProblems;
    private bool refreshing;

    private readonly TextBlock configProblem = Ui.Status("", Ui.Caution);

    private readonly CheckBox launch = Ui.Switch(T("Start when you sign in", "Запускать при входе в Windows"));
    private readonly TextBlock micStatus = Ui.Status();
    private readonly System.Windows.Controls.Button micSettings;

    private readonly CheckBox cloud = Ui.Switch(T("In the cloud", "В облаке"));
    private readonly Dictionary<string, RadioButton> providerCards = [];
    private readonly Dictionary<string, TextBlock> providerStatus = [];
    private readonly StackPanel keyLine = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
    private readonly PasswordBox cloudKey;
    private readonly TextBlock cloudKeyStatus = Ui.Status();
    private readonly StackPanel keySaved = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
    private readonly TextBlock keySavedText = Ui.Status();
    private string? pendingProvider;
    private bool replacingKey;

    private readonly CheckBox local = Ui.Switch(T("On this computer", "На этом компьютере"));
    private TextBlock localDetail = Ui.Detail("");
    private readonly Dictionary<string, RadioButton> localCards = [];
    private readonly Dictionary<string, TextBlock> localStatus = [];
    private readonly Dictionary<string, System.Windows.Controls.Button> localDownload = [];
    private readonly ProgressBar downloadBar = new() { Width = 120, Height = 4, Minimum = 0, Maximum = 100, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock downloadStatus = Ui.Status();
    private readonly Dictionary<string, string> downloadErrors = [];

    private readonly ComboBox language = new() { MinWidth = 220 };
    private readonly TextBlock languageNote = Ui.Status();
    private readonly CheckBox live = Ui.Switch(T("Live transcript", "Расшифровка на ходу"));

    private readonly TextBlock folderPath = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock folderDetail = Ui.Detail(FolderAdvice);
    private readonly CheckBox keepAudio = Ui.Switch(T("Keep the audio after transcribing", "Оставлять звук после расшифровки"));

    private readonly CheckBox summaries = Ui.Switch(T("Write summaries", "Писать саммари"));
    private readonly Dictionary<string, RadioButton> summaryCards = [];
    private readonly Dictionary<string, TextBlock> summaryStatus = [];
    private readonly ComboBox keyProvider = new() { Width = 150, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly PasswordBox summaryKey;
    private readonly FrameworkElement summaryKeyView;
    private readonly TextBlock summaryKeyStatus = Ui.Status();
    private readonly StackPanel openAiOptions = new();
    private readonly TextBox openAiBaseUrl;
    private readonly TextBox openAiModel;
    private readonly TextBox ollamaBaseUrl;
    private readonly TextBox ollamaModel;

    private readonly CheckBox tray = Ui.Switch(T("In the notification area", "В области уведомлений"));
    private readonly CheckBox taskbar = Ui.Switch(T("On the taskbar", "На панели задач"));
    private readonly TextBlock noIconsNote = Ui.Status();
    private readonly CheckBox autoRecord = Ui.Switch(T("Record meetings automatically", "Записывать встречи сама"));
    private readonly TextBlock autoRecordDetail = Ui.Detail("");
    private readonly CheckBox analytics = Ui.Switch(T("Send usage statistics", "Отправлять статистику об использовании"));

    public StackPanel View { get; } = new() { Margin = new Thickness(Ui.Gutter, 20, Ui.Gutter, 8) };

    /// <summary>Anything a host shows about the form may have changed — what is left to do.</summary>
    public event EventHandler? StateChanged;

    public SetupForm(AmanuRuntime runtime, bool showsConfigProblems = true)
    {
        this.runtime = runtime;
        this.showsConfigProblems = showsConfigProblems;
        micSettings = Ui.Button(T("Open settings", "Открыть параметры"), MicrophoneAccess.OpenSettings);
        (var cloudKeyView, cloudKey) = Ui.Secret(T("paste key", "вставьте ключ"), 260);
        (summaryKeyView, summaryKey) = Ui.Secret("sk-…", 260);
        (var openAiBaseView, openAiBaseUrl) = Ui.Field("https://api.openai.com/v1");
        (var openAiModelView, openAiModel) = Ui.Field("gpt-5");
        (var ollamaBaseView, ollamaBaseUrl) = Ui.Field("http://127.0.0.1:11434");
        (var ollamaModelView, ollamaModel) = Ui.Field("qwen3:8b");

        configProblem.Margin = new Thickness(0, 0, 0, 16);
        configProblem.Visibility = Visibility.Collapsed;
        View.Children.Add(configProblem);

        View.Children.Add(Ui.Section(T("Access", "Доступ"), Ui.Box(
            Ui.Row(launch,
                Ui.Title(T("Start when you sign in to Windows", "Запускать при входе в Windows")),
                Ui.Detail(T("So a meeting is never missed because nobody opened Amanu.", "Чтобы встреча не пропала из-за того, что Amanu никто не открыл."))),
            Ui.Row(Ui.Symbol(""),
                Ui.Title(T("Microphone", "Микрофон")),
                Ui.Detail(T("Your side of the call. Windows asks for it under Privacy › Microphone.",
                    "Ваша сторона разговора. Windows разрешает его в «Конфиденциальность › Микрофон».")),
                micStatus, micSettings),
            Ui.Row(Ui.Symbol(""),
                Ui.Title(T("Call audio", "Звук звонка")),
                Ui.Detail(T("Windows needs no permission for it. Amanu records only the call app’s own sound; in a browser, other tabs of the same browser can be heard too.",
                    "Windows не спрашивает на него разрешения. Amanu записывает только звук самого приложения звонка; в браузере могут попасть и другие его вкладки."))))));

        View.Children.Add(Ui.Section(T("Transcription", "Расшифровка"), Ui.Group(14,
            TranscriptionBox(cloudKeyView),
            LanguageRow(),
            Ui.Box(Ui.Row(live,
                Ui.Title(T("I want a live transcript during meetings", "Показывать расшифровку прямо во время встречи")),
                Ui.Detail(T("Every 20 seconds a piece of the recording is transcribed by the same engine as the final transcript — the local model when it is downloaded. The final transcript is still made afterwards.",
                    "Каждые 20 секунд кусок записи расшифровывается тем же движком, что и итоговая расшифровка, — локальной моделью, если она скачана. Итоговая расшифровка всё равно делается после встречи.")))))));

        View.Children.Add(Ui.Section(T("Files", "Файлы"), Ui.Box(
            Ui.Row(Ui.Symbol(""), folderPath, folderDetail, Ui.Button(T("Choose…", "Выбрать…"), ChooseFolder)),
            Ui.Row(Ui.Symbol(""), Ui.Title(T("Keep the audio after transcribing", "Оставлять звук после расшифровки")),
                Ui.Detail(T("One stereo M4A: your mic on the left, the other side on the right.",
                    "Один стереофайл M4A: ваш микрофон слева, собеседники справа.")), keepAudio))));

        View.Children.Add(Ui.Section(T("Summaries", "Саммари"), SummaryChoices(openAiBaseView, openAiModelView, ollamaBaseView, ollamaModelView), summaries));

        noIconsNote.Margin = new Thickness(0, Ui.HeaderGap, 0, 0);
        View.Children.Add(Ui.Section(T("Where Amanu shows up", "Где видно Amanu"), Ui.Group(0,
            Ui.Box(
                Ui.Row(tray, Ui.Title(T("In the notification area", "В области уведомлений")),
                    Ui.Detail(T("The icon by the clock, with a red dot while a meeting records — and the menu with everything in it.",
                        "Значок у часов, во время встречи на нём красная точка, и меню со всем остальным."))),
                Ui.Row(taskbar, Ui.Title(T("On the taskbar", "На панели задач")),
                    Ui.Detail(T("The Amanu window on the taskbar and in Alt+Tab, like any other program.",
                        "Окно Amanu на панели задач и в Alt+Tab, как у любой программы.")))),
            noIconsNote)));

        var autoBox = Ui.Box(Ui.Row(autoRecord,
            Ui.Title(T("Start recording automatically when a call app takes the mic", "Начинать запись, когда приложение звонка берёт микрофон")),
            autoRecordDetail));
        autoBox.Margin = new Thickness(0, 0, 0, Ui.SectionGap);
        View.Children.Add(autoBox);

        var analyticsBox = Ui.Box(Ui.Row(analytics,
            Ui.Title(T("Send usage statistics", "Отправлять статистику об использовании")),
            Ui.Detail(T("Feature usage with a random installation identifier; no meeting content.",
                "Использование функций со случайным идентификатором установки; без содержимого встреч.")),
            Ui.Link(T("What exactly", "Что именно"), "https://github.com/gsamat/amanu/blob/master/docs/analytics.md")));
        View.Children.Add(analyticsBox);

        Wire();
        runtime.SettingsChanged += OnSettingsChanged;
        runtime.DownloadProgressChanged += OnDownloadProgress;
        Refresh();
        _ = DetectToolsAsync();
    }

    public void Detach()
    {
        runtime.SettingsChanged -= OnSettingsChanged;
        runtime.DownloadProgressChanged -= OnDownloadProgress;
    }

    private void OnSettingsChanged(object? sender, EventArgs e) => View.Dispatcher.InvokeAsync(Refresh);

    private Window? Owner => Ui.OwnerOf(View);

    // MARK: building

    private Border TranscriptionBox(FrameworkElement cloudKeyView)
    {
        var cloudRow = Ui.Row(cloud, Ui.Title(T("In the cloud", "В облаке")),
            Ui.Detail(T("Audio is uploaded to the provider’s servers. Better on Russian, and tells apart multiple speakers.",
                "Звук уходит на серверы провайдера. Лучше слышит русский и различает нескольких говорящих.")));

        var providers = new (string Id, string Title, string Detail, string Url)[]
        {
            ("assemblyai", "AssemblyAI", T("$0.23 an hour. No limit on meeting length.", "$0,23 за час. Без ограничения на длину встречи."), "https://www.assemblyai.com/dashboard/signup"),
            ("openai", "OpenAI", T("$0.36 an hour. Same key as summaries.", "$0,36 за час. Тот же ключ, что и для саммари."), "https://platform.openai.com/api-keys"),
            ("elevenlabs", "ElevenLabs", T("Scribe v2. $0.44 an hour for a two-channel call.", "Scribe v2. $0,44 за час разговора с двумя каналами."), "https://elevenlabs.io/app/developers/api-keys"),
        };
        foreach (var (id, title, detail, url) in providers)
        {
            var status = Ui.Status();
            providerStatus[id] = status;
            providerCards[id] = Ui.Card(id, title, detail, status, Ui.Link(T("Get a key", "Получить ключ"), url));
            providerCards[id].GroupName = "provider";
        }
        keyLine.Children.Add(cloudKeyView);
        cloudKeyStatus.Margin = new Thickness(10, 0, 0, 0);
        keyLine.Children.Add(cloudKeyStatus);
        keySaved.Children.Add(keySavedText);
        var replace = Ui.Button(T("Replace key…", "Заменить ключ…"), () => { replacingKey = true; Refresh(); cloudKey.Focus(); });
        replace.Margin = new Thickness(10, 0, 0, 0);
        keySaved.Children.Add(replace);
        var providerOptions = new StackPanel { Margin = new Thickness(16 + Ui.Indent, 0, 16, 14) };
        providerOptions.Children.Add(Ui.Cards([.. providerCards.Values]));
        providerOptions.Children.Add(keyLine);
        providerOptions.Children.Add(keySaved);

        localDetail = Ui.Detail(T("Nothing leaves the computer; local transcripts label speakers as me / them.",
            "С компьютера ничего не уходит; локальные расшифровки помечают спикеров как «я»/«они»."));
        var localRow = Ui.Row(local, Ui.Title(T("On this computer", "На этом компьютере")), localDetail);
        var models = new (string Id, string Title, string Detail)[]
        {
            ("parakeet", "Parakeet v3", T("Fastest · about 740 MB", "Самая быстрая · около 740 МБ")),
            ("whisper", "Whisper large-v3-turbo", T("Best multilingual accuracy · about 890 MB", "Лучшая точность на разных языках · около 890 МБ")),
            ("gigaam", "GigaAM v3", T("Alternative for Russian · about 270 MB", "Альтернатива для русского · около 270 МБ")),
        };
        foreach (var (id, title, detail) in models)
        {
            var status = Ui.Status();
            localStatus[id] = status;
            var download = Ui.Button(T("Download…", "Скачать…"), () => _ = DownloadAsync(id));
            download.HorizontalAlignment = HorizontalAlignment.Left;
            localDownload[id] = download;
            localCards[id] = Ui.Card(id, title, detail, status, download);
            localCards[id].GroupName = "local";
        }
        var progress = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        progress.Children.Add(downloadBar);
        downloadStatus.Margin = new Thickness(10, 0, 0, 0);
        progress.Children.Add(downloadStatus);
        var localOptions = new StackPanel { Margin = new Thickness(16 + Ui.Indent, 0, 16, 14) };
        localOptions.Children.Add(Ui.Cards([.. localCards.Values]));
        localOptions.Children.Add(progress);

        var cloudBlock = new StackPanel();
        cloudBlock.Children.Add(cloudRow);
        cloudBlock.Children.Add(providerOptions);
        var localBlock = new StackPanel();
        localBlock.Children.Add(localRow);
        localBlock.Children.Add(localOptions);
        return Ui.Box(cloudBlock, localBlock);
    }

    private StackPanel LanguageRow()
    {
        language.Items.Add(new ComboBoxItem { Content = T("Detect automatically", "Определять автоматически"), Tag = "" });
        var menu = MeetingLanguages.Menu;
        for (var index = 0; index < menu.Count; index++)
        {
            if (index == MeetingLanguages.Pinned.Count) language.Items.Add(new Separator());
            language.Items.Add(new ComboBoxItem { Content = MeetingLanguages.Names[menu[index]], Tag = menu[index] });
        }
        System.Windows.Automation.AutomationProperties.SetName(language, T("Meetings are mostly in", "Чаще всего встречи на языке"));
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        var label = Ui.Status(T("Meetings are mostly in", "Чаще всего встречи на языке"));
        label.FontSize = 14;
        label.Margin = new Thickness(0, 0, 12, 0);
        line.Children.Add(label);
        line.Children.Add(language);
        var stack = new StackPanel();
        stack.Children.Add(line);
        languageNote.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(languageNote);
        return stack;
    }

    private StackPanel SummaryChoices(FrameworkElement openAiBaseView, FrameworkElement openAiModelView,
        FrameworkElement ollamaBaseView, FrameworkElement ollamaModelView)
    {
        foreach (var id in new[] { "claude-cli", "codex-cli", "api-key", "ollama" }) summaryStatus[id] = Ui.Status();
        summaryCards["claude-cli"] = Ui.Card("claude-cli", "Claude Code",
            T("On the subscription you’re already signed into. No key.", "По подписке, в которую вы уже вошли. Ключ не нужен."),
            summaryStatus["claude-cli"], Ui.Link(T("Install it", "Установить"), "https://claude.com/product/claude-code"));
        summaryCards["codex-cli"] = Ui.Card("codex-cli", "Codex",
            T("Same deal, on your OpenAI subscription.", "То же самое, но по подписке OpenAI."),
            summaryStatus["codex-cli"], Ui.Link(T("Install it", "Установить"), "https://developers.openai.com/codex/cli/"));

        keyProvider.Items.Add(new ComboBoxItem { Content = "Anthropic", Tag = "anthropic-api" });
        keyProvider.Items.Add(new ComboBoxItem { Content = "OpenAI", Tag = "openai-api" });
        openAiOptions.Children.Add(FieldRow(T("Base URL", "URL сервера"), openAiBaseView));
        openAiOptions.Children.Add(FieldRow(T("Model", "Модель"), openAiModelView));
        summaryCards["api-key"] = Ui.Card("api-key", T("My own key", "Свой ключ"),
            T("Billed per meeting, needs no CLI.", "Оплата за встречу, без CLI."),
            keyProvider, summaryKeyView, openAiOptions, summaryKeyStatus,
            Ui.Link(T("Get a key", "Получить ключ"), "https://console.anthropic.com/settings/keys"));

        var ollamaFields = new StackPanel();
        ollamaFields.Children.Add(FieldRow(T("Base URL", "URL сервера"), ollamaBaseView));
        ollamaFields.Children.Add(FieldRow(T("Model", "Модель"), ollamaModelView));
        summaryCards["ollama"] = Ui.Card("ollama", "Ollama",
            T("Local by default. A remote URL sends the transcript there.", "По умолчанию локально. Удалённый URL получит расшифровку."),
            ollamaFields, summaryStatus["ollama"], Ui.Link(T("Install Ollama", "Установить Ollama"), "https://ollama.com/download/windows"));

        foreach (var card in summaryCards.Values) card.GroupName = "summary";
        var disclosure = Ui.Detail(T("Claude, Codex and API models receive meeting content. Ollama stays on this computer only with a localhost URL.",
            "Claude, Codex и API-модели получают данные встречи. Ollama остаётся на этом компьютере только с адресом localhost."));
        return Ui.Group(Ui.CardGap,
            Ui.Cards(summaryCards["claude-cli"], summaryCards["codex-cli"], summaryCards["api-key"]),
            summaryCards["ollama"],
            disclosure);
    }

    private static Grid FieldRow(string label, FrameworkElement field)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var text = Ui.Status(label);
        grid.Children.Add(text);
        Grid.SetColumn(field, 1);
        grid.Children.Add(field);
        return grid;
    }

    // MARK: actions

    private void Wire()
    {
        launch.Click += (_, _) => Change(settings => settings.StartAtLogin = launch.IsChecked == true);
        cloud.Click += (_, _) => ChangeTranscription(choice => choice with { Cloud = cloud.IsChecked == true });
        local.Click += (_, _) =>
        {
            ChangeTranscription(choice => choice with { Local = local.IsChecked == true });
            var model = runtime.Settings.Transcription.LocalEngine;
            if (local.IsChecked == true && !runtime.IsLocalModelReady(model)) _ = DownloadAsync(model);
        };
        foreach (var (id, card) in providerCards) card.Click += (_, _) => ProviderPicked(id);
        foreach (var (id, card) in localCards)
            card.Click += (_, _) => ChangeTranscription(choice => choice with { LocalEngine = id });
        cloudKey.KeyDown += (_, args) => { if (args.Key == Key.Enter) _ = SaveCloudKeyAsync(); };
        cloudKey.LostKeyboardFocus += (_, _) => _ = SaveCloudKeyAsync();
        language.SelectionChanged += (_, _) =>
        {
            if (refreshing || language.SelectedItem is not ComboBoxItem { Tag: string code }) return;
            Set("transcription.language", code.Length == 0 ? null : JsonValue.Create(code));
        };
        live.Click += (_, _) => Change(settings => settings.LiveTranscription.Enabled = live.IsChecked == true);
        keepAudio.Click += (_, _) => Change(settings => settings.KeepAudio = keepAudio.IsChecked == true);

        summaries.Click += (_, _) => Change(settings => settings.Summary.Enabled = summaries.IsChecked == true);
        foreach (var (id, card) in summaryCards)
            card.Click += (_, _) => Change(settings => settings.Summary.Backend = id == "api-key" ? SelectedKeyBackend : id);
        keyProvider.SelectionChanged += (_, _) =>
        {
            if (refreshing) return;
            if (summaryCards["api-key"].IsChecked == true) Change(settings => settings.Summary.Backend = SelectedKeyBackend);
            else Refresh();
        };
        summaryKey.KeyDown += (_, args) => { if (args.Key == Key.Enter) _ = SaveSummaryKeyAsync(); };
        summaryKey.LostKeyboardFocus += (_, _) => _ = SaveSummaryKeyAsync();
        CommitOnLeave(openAiBaseUrl, "summary.openai_base_url", server: true);
        CommitOnLeave(openAiModel, "summary.openai_model");
        CommitOnLeave(ollamaBaseUrl, "summary.ollama_base_url", server: true);
        CommitOnLeave(ollamaModel, "summary.ollama_model");

        tray.Click += (_, _) => Change(settings => settings.TrayIcon = tray.IsChecked == true);
        taskbar.Click += (_, _) => Change(settings => settings.TaskbarIcon = taskbar.IsChecked == true);
        autoRecord.Click += (_, _) => Change(settings => settings.AutoRecord.Enabled = autoRecord.IsChecked == true);
        analytics.Click += (_, _) => Change(settings => settings.Analytics = analytics.IsChecked == true);
    }

    private string SelectedKeyBackend => (keyProvider.SelectedItem as ComboBoxItem)?.Tag as string ?? "anthropic-api";

    private void Change(Action<AppSettings> change)
    {
        if (!Ui.TryUpdate(Owner, () => runtime.Update(change))) Refresh();
    }

    private void Set(string path, JsonNode? value)
    {
        if (!Ui.TryUpdate(Owner, () => runtime.SetValue(path, value))) Refresh();
    }

    private void ChangeTranscription(Func<SetupChoice, SetupChoice> change) => Change(settings =>
    {
        var transcription = settings.Transcription;
        change(SetupChoice.Read(transcription.Enabled, transcription.Engine, transcription.Cloud, transcription.LocalEngine))
            .ApplyTo(transcription);
    });

    /// <summary>
    /// A provider with a key is taken up at once. One without a key opens the key
    /// field and leaves the provider in force alone until a key arrives, so a
    /// curious click cannot cost the next meeting its transcript.
    /// </summary>
    private void ProviderPicked(string id)
    {
        var current = runtime.Settings.Transcription.Cloud;
        if (HasKey(id) || !HasKey(current))
        {
            pendingProvider = null;
            ChangeTranscription(choice => choice with { Provider = id });
        }
        else
        {
            pendingProvider = id;
            Refresh();
            cloudKey.Focus();
        }
    }

    private bool HasKey(string name) => !string.IsNullOrWhiteSpace(runtime.GetSecret(name));

    private string ShownProvider => pendingProvider ?? runtime.Settings.Transcription.Cloud;

    private async Task SaveCloudKeyAsync()
    {
        var key = cloudKey.Password.Trim();
        if (key.Length == 0) return;
        var provider = ShownProvider;
        var saved = await CheckAndSaveAsync(provider, key, cloudKeyStatus);
        if (!saved) return;
        cloudKey.Clear();
        replacingKey = false;
        if (pendingProvider == provider)
        {
            pendingProvider = null;
            ChangeTranscription(choice => choice with { Provider = provider });
        }
        Refresh();
    }

    private string SummaryKeySlot => SelectedKeyBackend == "anthropic-api" ? SecretNames.Anthropic
        : Uri.TryCreate(runtime.Settings.Summary.OpenAiBaseUrl, UriKind.Absolute, out var uri) && KeyRouting.IsOpenAi(uri)
            ? SecretNames.OpenAi : SecretNames.OpenAiCompatible;

    private async Task SaveSummaryKeyAsync()
    {
        var key = summaryKey.Password.Trim();
        if (key.Length == 0) return;
        var slot = SummaryKeySlot;
        bool saved;
        if (slot == SecretNames.OpenAiCompatible)
        {
            // A compatible server has no one place to check a key against.
            runtime.SetSecret(slot, key);
            summaryKeyStatus.Text = T("saved", "сохранён");
            saved = true;
        }
        else saved = await CheckAndSaveAsync(slot, key, summaryKeyStatus);
        if (saved) summaryKey.Clear();
        Refresh();
    }

    private async Task<bool> CheckAndSaveAsync(string slot, string key, TextBlock status)
    {
        status.Text = T("checking…", "проверяю…");
        status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Secondary);
        var (verdict, message) = await KeyCheck.CheckAsync(runtime.Http, slot, key, CancellationToken.None);
        status.Text = message;
        if (verdict == KeyVerdict.Refused)
        {
            status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Critical);
            return false;
        }
        try
        {
            runtime.SetSecret(slot, key);
        }
        catch (System.ComponentModel.Win32Exception exception)
        {
            status.Text = T("couldn’t save the key: ", "не удалось сохранить ключ: ") + exception.Message;
            status.SetResourceReference(TextBlock.ForegroundProperty, Ui.Critical);
            return false;
        }
        status.SetResourceReference(TextBlock.ForegroundProperty, verdict == KeyVerdict.Works ? Ui.Good : Ui.Secondary);
        return true;
    }

    private void CommitOnLeave(TextBox box, string path, bool server = false)
    {
        void Commit()
        {
            if (refreshing) return;
            var text = box.Text.Trim();
            var stored = runtime.GetValue(path)?.ToString() ?? "";
            if (text == stored) return;
            if (server && text.Length > 0 && !KeyRouting.AcceptableServer(text))
            {
                Ui.ShowError(Owner, T("This address can’t be used", "Этот адрес не подходит"),
                    T("Anything not on this computer must be reached over https, because it will see the meeting.",
                      "Всё, что не на этом компьютере, должно быть по https: этот сервер увидит содержимое встречи."));
                box.Text = stored;
                return;
            }
            Set(path, text.Length == 0 ? null : JsonValue.Create(text));
        }
        box.LostKeyboardFocus += (_, _) => Commit();
        box.KeyDown += (_, args) => { if (args.Key == Key.Enter) Commit(); };
    }

    private void ChooseFolder()
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog
        {
            Title = T("Where recordings go", "Куда складывать записи"),
            InitialDirectory = runtime.Settings.RecordingsDirectory,
        };
        if (dialog.ShowDialog(Owner) != true) return;
        Change(settings => settings.RecordingsDirectory = dialog.FolderName);
        // A recording running now finishes in the folder it started in, and that is
        // worth saying before somebody goes looking for it in the new one.
        folderDetail.Text = runtime.State.IsRecording
            ? T("The recording in progress stays in the old folder; the next one goes here.",
                "Идущая запись останется в старой папке, следующая ляжет сюда.")
            : FolderAdvice;
    }

    private static string FolderAdvice => T("Recordings, transcripts and summaries live here.", "Здесь лежат записи, расшифровки и саммари.");

    private async Task DownloadAsync(string model)
    {
        downloadErrors.Remove(model);
        downloadBar.Visibility = Visibility.Visible;
        downloadBar.Value = 0;
        downloadStatus.Text = T("preparing download…", "готовлюсь скачивать…");
        localDownload[model].IsEnabled = false;
        try
        {
            await runtime.EnsureLocalModelAsync(model);
            downloadStatus.Text = "";
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException or InvalidOperationException or TaskCanceledException)
        {
            downloadErrors[model] = T("download failed: ", "не удалось скачать: ") + exception.Message;
            downloadStatus.Text = downloadErrors[model];
        }
        finally
        {
            downloadBar.Visibility = Visibility.Collapsed;
            Refresh();
        }
    }

    private void OnDownloadProgress(object? sender, DownloadProgress progress) => View.Dispatcher.InvokeAsync(() =>
    {
        downloadBar.Visibility = Visibility.Visible;
        downloadBar.Value = progress.Percentage;
        var name = EngineResolver.DisplayName(progress.Item.Replace("Model ", "", StringComparison.Ordinal));
        downloadStatus.Text = $"{name}: {Ui.Megabytes(progress.Received)} / {Ui.Megabytes(progress.Total)}";
    });

    private async Task DetectToolsAsync()
    {
        var claude = CliProbe.DescribeAsync("claude");
        var codex = CliProbe.DescribeAsync("codex");
        summaryStatus["claude-cli"].Text = await claude;
        summaryStatus["codex-cli"].Text = await codex;
        summaryStatus["ollama"].Text = await OllamaStatusAsync();
    }

    private async Task<string> OllamaStatusAsync()
    {
        var url = runtime.Settings.Summary.OllamaBaseUrl.TrimEnd('/');
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            using var response = await runtime.Http.GetAsync(url + "/api/tags", timeout.Token);
            var remote = Uri.TryCreate(url, UriKind.Absolute, out var uri) && !KeyRouting.IsLocal(uri);
            return T("running", "работает") + (remote ? T(" · remote", " · удалённо") : "");
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
        {
            return T("not running here", "здесь не запущена");
        }
    }

    // MARK: refresh

    /// <summary>Everything redrawn from the settings, the keys and the disk — never from what the controls last said.</summary>
    public void Refresh()
    {
        refreshing = true;
        try
        {
            var settings = runtime.Settings;
            var problems = runtime.ConfigProblems;
            configProblem.Visibility = showsConfigProblems && problems.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            configProblem.Text = string.Join(Environment.NewLine, problems.Select(problem => problem.Explanation));

            launch.IsChecked = settings.StartAtLogin;
            var mic = MicrophoneAccess.Read();
            micStatus.Text = mic switch
            {
                MicrophoneAccess.State.Allowed => T("allowed", "разрешено"),
                MicrophoneAccess.State.DeniedForDesktopApps => T("off for desktop apps", "выключено для классических приложений"),
                MicrophoneAccess.State.DeniedForEveryone => T("off", "выключено"),
                _ => "",
            };
            micStatus.SetResourceReference(TextBlock.ForegroundProperty, mic is MicrophoneAccess.State.Allowed or MicrophoneAccess.State.Unknown ? Ui.Good : Ui.Critical);
            micSettings.Visibility = mic is MicrophoneAccess.State.Allowed ? Visibility.Collapsed : Visibility.Visible;

            var choice = SetupChoice.Read(settings.Transcription.Enabled, settings.Transcription.Engine, settings.Transcription.Cloud, settings.Transcription.LocalEngine);
            cloud.IsChecked = choice.Cloud;
            local.IsChecked = choice.Local;
            local.IsEnabled = runtime.LocalRuntimePresent;
            localDetail.Text = runtime.LocalRuntimePresent
                ? T("Nothing leaves the computer; local transcripts label speakers as me / them.", "С компьютера ничего не уходит; локальные расшифровки помечают спикеров как «я»/«они».")
                : T("This build of Amanu has no local transcription engine.", "В этой сборке Amanu нет локального движка расшифровки.");
            var shown = ShownProvider;
            foreach (var (id, card) in providerCards)
            {
                card.IsChecked = id == shown;
                providerStatus[id].Text = HasKey(id) ? T("key saved", "ключ сохранён") : T("no key yet", "ключа ещё нет");
                providerStatus[id].SetResourceReference(TextBlock.ForegroundProperty,
                    !HasKey(id) && id == shown && choice.Cloud ? Ui.Caution : HasKey(id) ? Ui.Good : Ui.Secondary);
            }
            var shownHasKey = HasKey(shown);
            keyLine.Visibility = !shownHasKey || replacingKey ? Visibility.Visible : Visibility.Collapsed;
            keySaved.Visibility = keyLine.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
            keySavedText.Text = T($"The {EngineResolver.DisplayName(shown)} key is kept in Windows Credential Manager.",
                $"Ключ {EngineResolver.DisplayName(shown)} хранится в диспетчере учётных данных Windows.");
            if (pendingProvider is not null && cloudKeyStatus.Text.Length == 0)
                cloudKeyStatus.Text = T($"paste a key to switch to {EngineResolver.DisplayName(pendingProvider)}",
                    $"вставьте ключ, чтобы перейти на {EngineResolver.DisplayName(pendingProvider)}");

            foreach (var (id, card) in localCards)
            {
                card.IsChecked = id == choice.LocalEngine;
                var bytes = runtime.LocalModelBytes(id);
                var ready = runtime.IsLocalModelReady(id);
                localStatus[id].Text = ready && bytes is { } size ? T("downloaded · ", "скачана · ") + Ui.Megabytes(size)
                    : downloadErrors.GetValueOrDefault(id) ?? (!runtime.LocalRuntimePresent ? T("unavailable", "недоступна") : "");
                localStatus[id].SetResourceReference(TextBlock.ForegroundProperty, ready ? Ui.Good : downloadErrors.ContainsKey(id) ? Ui.Critical : Ui.Secondary);
                localDownload[id].Visibility = ready || !runtime.LocalRuntimePresent ? Visibility.Collapsed : Visibility.Visible;
                localDownload[id].IsEnabled = downloadBar.Visibility != Visibility.Visible;
            }

            var code = settings.Transcription.Language ?? "";
            language.SelectedItem = language.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (string)item.Tag == code)
                ?? AddLanguage(code);
            var expected = MeetingLanguages.Expected(settings.Transcription.Language);
            languageNote.Text = expected.Count switch
            {
                0 => T("The engines detect the language from the audio, whatever it is.", "Движки определяют язык по звуку, какой бы он ни был."),
                1 => T("Only English is expected, so every engine is told so outright.", "Ожидается только английский, и движки получают его напрямую."),
                _ => T($"{MeetingLanguages.Names[expected[0]]} and English are expected; the engines still decide which they heard. Naming the language keeps a short or noisy meeting from being taken for another one.",
                       $"Ожидаются {MeetingLanguages.Names[expected[0]]} и английский; какой прозвучал, движки решают сами. Названный язык не даст принять короткую или шумную встречу за другую."),
            };
            live.IsChecked = settings.LiveTranscription.Enabled;
            live.IsEnabled = choice.Enabled;

            folderPath.Text = settings.RecordingsDirectory;
            keepAudio.IsChecked = settings.KeepAudio;

            summaries.IsChecked = settings.Summary.Enabled;
            var backend = settings.Summary.Backend;
            var chosen = backend is "anthropic-api" or "openai-api" ? "api-key" : backend;
            foreach (var (id, item) in summaryCards)
            {
                item.IsChecked = id == chosen;
                item.IsEnabled = settings.Summary.Enabled;
            }
            if (backend is "anthropic-api" or "openai-api")
                keyProvider.SelectedItem = keyProvider.Items.OfType<ComboBoxItem>().First(item => (string)item.Tag == backend);
            else keyProvider.SelectedIndex = keyProvider.SelectedIndex < 0 ? 0 : keyProvider.SelectedIndex;
            var openAi = SelectedKeyBackend == "openai-api";
            openAiOptions.Visibility = openAi ? Visibility.Visible : Visibility.Collapsed;
            summaryKeyStatus.Text = HasKey(SummaryKeySlot) ? T("key saved", "ключ сохранён") : T("no key yet", "ключа ещё нет");
            summaryKeyStatus.SetResourceReference(TextBlock.ForegroundProperty, HasKey(SummaryKeySlot) ? Ui.Good : Ui.Secondary);
            if (!openAiBaseUrl.IsKeyboardFocused) openAiBaseUrl.Text = settings.Summary.OpenAiBaseUrl == new SummarySettings().OpenAiBaseUrl ? "" : settings.Summary.OpenAiBaseUrl;
            if (!openAiModel.IsKeyboardFocused) openAiModel.Text = settings.Summary.OpenAiModel == new SummarySettings().OpenAiModel ? "" : settings.Summary.OpenAiModel;
            if (!ollamaBaseUrl.IsKeyboardFocused) ollamaBaseUrl.Text = settings.Summary.OllamaBaseUrl == new SummarySettings().OllamaBaseUrl ? "" : settings.Summary.OllamaBaseUrl;
            if (!ollamaModel.IsKeyboardFocused) ollamaModel.Text = settings.Summary.OllamaModel == new SummarySettings().OllamaModel ? "" : settings.Summary.OllamaModel;

            tray.IsChecked = settings.TrayIcon;
            taskbar.IsChecked = settings.TaskbarIcon;
            noIconsNote.Text = settings.TrayIcon || settings.TaskbarIcon ? ""
                : T("Amanu keeps recording with no icon anywhere. To bring the window back, open Amanu again from the Start menu.",
                    "Amanu продолжит записывать, но её нигде не будет видно. Чтобы вернуть окно, откройте Amanu ещё раз из меню «Пуск».");
            noIconsNote.Visibility = noIconsNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            autoRecord.IsChecked = settings.AutoRecord.Enabled;
            autoRecordDetail.Text = T($"And stop when it lets go. A call shorter than {settings.AutoRecord.MinimumDurationSeconds} seconds is thrown away.",
                $"И заканчивать, когда отпустит. Звонок короче {settings.AutoRecord.MinimumDurationSeconds} секунд выбрасывается.");
            analytics.IsChecked = settings.Analytics;
        }
        finally
        {
            refreshing = false;
        }
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private ComboBoxItem AddLanguage(string code)
    {
        var item = new ComboBoxItem { Content = code, Tag = code };
        language.Items.Add(item);
        return item;
    }

    /// <summary>What still stands between this computer and a transcribed, summarized meeting.</summary>
    public IReadOnlyList<string> Outstanding()
    {
        var settings = runtime.Settings;
        var left = new List<string>();
        if (MicrophoneAccess.Read() is MicrophoneAccess.State.DeniedForDesktopApps or MicrophoneAccess.State.DeniedForEveryone)
            left.Add(T("the microphone", "микрофон"));
        if (settings.Transcription.Enabled)
        {
            var plan = EngineResolver.Plan(settings.Transcription.Engine, settings.Transcription.Cloud, settings.Transcription.LocalEngine,
                HasKey, runtime.IsLocalModelReady);
            if (!plan.Usable) left.Add(T("a transcription key or model", "ключ или модель для расшифровки"));
        }
        if (settings.Summary.Enabled && settings.Summary.Backend != "none" && runtime.LanguageModels.For(EgressPurpose.Summary).Count == 0)
            left.Add(T("a model for summaries", "модель для саммари"));
        return left;
    }
}
