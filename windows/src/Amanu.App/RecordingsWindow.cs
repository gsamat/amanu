using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using static Amanu.Core.Localization.Localized;
using ContextMenu = System.Windows.Controls.ContextMenu;
using DataGrid = System.Windows.Controls.DataGrid;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using MenuItem = System.Windows.Controls.MenuItem;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;

namespace Amanu.App;

/// <summary>
/// Every meeting in the recordings folder, what has been done with it, and the
/// few things worth doing to one by hand: finish what gave up, transcribe again,
/// put a name to a voice, listen, open, delete.
/// </summary>
internal sealed class RecordingsWindow : Window
{
    private readonly AmanuRuntime runtime;
    private readonly DataGrid grid = new()
    {
        AutoGenerateColumns = false,
        IsReadOnly = true,
        SelectionMode = DataGridSelectionMode.Single,
        HeadersVisibility = DataGridHeadersVisibility.Column,
        GridLinesVisibility = DataGridGridLinesVisibility.None,
        CanUserResizeRows = false,
    };
    private readonly TextBlock title = Ui.Title("");
    private readonly TextBlock problem = Ui.Status("", Ui.Caution);
    private readonly MarkdownPreview summary = new();
    private readonly MarkdownPreview transcript = new();
    private readonly TabControl engineTabs = new() { Margin = new Thickness(0, 8, 0, 0), Visibility = Visibility.Collapsed };
    private readonly TextBlock processingStatus = Ui.Status("");
    private readonly StackPanel speakers = new() { Margin = new Thickness(12) };
    private readonly TextBlock empty = Ui.Detail("");
    private readonly System.Windows.Controls.Button finish;
    private readonly System.Windows.Controls.Button retranscribe;
    private readonly System.Windows.Controls.Button listen;
    private readonly System.Windows.Controls.Button folder;
    private readonly System.Windows.Controls.Button delete;
    private readonly Grid detail = new();
    private readonly TabControl tabs = new() { Margin = new Thickness(0, 8, 0, 0) };
    private bool loading;
    private bool reloadRequested;
    private bool updatingChoices;
    private string? selectedTranscriptKey;
    private string? selectedTranscriptSession;
    private int transcriptShown;

    public RecordingsWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        Title = T("Recordings", "Записи");
        MinWidth = 760;
        MinHeight = 520;
        Ui.FitToWorkArea(this, 1040, 760);
        Icon = App.WindowIcon;

        grid.Columns.Add(Column(T("When", "Когда"), nameof(Row.When), 140));
        grid.Columns.Add(Column(T("Meeting", "Встреча"), nameof(Row.Meeting), 0));
        var transcriptColumn = Column(T("Transcripts", "Расшифровки"), nameof(Row.TranscriptText), 260);
        transcriptColumn.ElementStyle = new Style(typeof(TextBlock));
        transcriptColumn.ElementStyle.Setters.Add(new Setter(TextBlock.TextWrappingProperty, TextWrapping.Wrap));
        grid.Columns.Add(transcriptColumn);
        grid.Columns.Add(Column(T("Names", "Имена"), nameof(Row.NamesText), 90));
        grid.Columns.Add(Column(T("Summary", "Саммари"), nameof(Row.SummaryText), 130));
        grid.SelectionChanged += async (_, _) => await ShowSelectedAsync();
        grid.MouseDoubleClick += (_, _) => { if (Selected is { } row) OpenFolder(row); };

        finish = Ui.Button(T("Finish", "Доделать"), () => { if (Selected is { } row) runtime.FinishProcessing(row.Item.Directory); });
        finish.ToolTip = T("Try again whatever gave up or is waiting, keeping the transcript and every name typed by hand.",
            "Ещё раз попробовать то, что не получилось или ждёт, — расшифровка и имена, введённые вручную, остаются.");
        retranscribe = Ui.Button(T("Transcribe again ▾", "Расшифровать заново ▾"), OpenRetranscribeMenu);
        listen = Ui.Button(T("Listen", "Слушать"), () => { if (Selected is { } row) Listen(row); });
        folder = Ui.Button(T("Open folder", "Открыть папку"), () => { if (Selected is { } row) OpenFolder(row); });
        delete = Ui.Button(T("Delete", "Удалить"), () => { if (Selected is { } row) Delete(row); });

        var toolbar = new DockPanel { Margin = new Thickness(16, 12, 16, 8) };
        var import = Ui.Button(T("Import…", "Импортировать…"), () => _ = App.ImportAsync(this));
        var openRoot = Ui.Button(T("Open recordings folder", "Открыть папку записей"), () =>
        {
            runtime.TrackArtifact("recordings_root");
            AmanuRuntime.Open(runtime.Settings.RecordingsDirectory);
        });
        openRoot.Margin = new Thickness(8, 0, 0, 0);
        toolbar.Children.Add(import);
        toolbar.Children.Add(openRoot);
        var rootPath = Ui.Status(runtime.Settings.RecordingsDirectory);
        rootPath.HorizontalAlignment = HorizontalAlignment.Right;
        rootPath.TextTrimming = TextTrimming.CharacterEllipsis;
        toolbar.Children.Add(rootPath);

        tabs.Items.Add(new TabItem { Header = T("Transcript", "Расшифровка"), Content = transcript });
        tabs.Items.Add(new TabItem { Header = T("Speakers", "Участники"), Content = Ui.Scroll(speakers) });
        tabs.Items.Add(new TabItem { Header = T("Summary", "Саммари"), Content = summary });
        engineTabs.SelectionChanged += async (_, args) =>
        {
            if (!updatingChoices && args.Source == engineTabs) await ShowTranscriptAsync();
        };
        var transcriptPanel = new Grid();
        transcriptPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        transcriptPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        transcriptPanel.Children.Add(engineTabs);
        Grid.SetRow(tabs, 1);
        transcriptPanel.Children.Add(tabs);

        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var button in new[] { finish, retranscribe, listen, folder, delete })
        {
            ToolTipService.SetShowOnDisabled(button, true);
            button.Margin = new Thickness(0, 0, 8, 0);
            actions.Children.Add(button);
        }

        detail.Margin = new Thickness(16, 8, 16, 14);
        detail.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detail.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        detail.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        title.FontSize = 18;
        title.FontWeight = FontWeights.SemiBold;
        detail.Children.Add(title);
        Grid.SetRow(problem, 1);
        problem.Margin = new Thickness(0, 4, 0, 0);
        var statusPanel = new StackPanel();
        statusPanel.Children.Add(processingStatus);
        statusPanel.Children.Add(problem);
        Grid.SetRow(statusPanel, 1);
        detail.Children.Add(statusPanel);
        Grid.SetRow(transcriptPanel, 2);
        detail.Children.Add(transcriptPanel);
        Grid.SetRow(actions, 3);
        detail.Children.Add(actions);

        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(2, GridUnitType.Star), MinHeight = 140 });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(3, GridUnitType.Star), MinHeight = 200 });
        layout.Children.Add(toolbar);
        grid.Margin = new Thickness(16, 0, 16, 0);
        Grid.SetRow(grid, 1);
        layout.Children.Add(grid);
        empty.Margin = new Thickness(32);
        empty.HorizontalAlignment = HorizontalAlignment.Center;
        empty.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetRow(empty, 1);
        layout.Children.Add(empty);
        var splitter = new GridSplitter { Height = 6, HorizontalAlignment = HorizontalAlignment.Stretch, Background = System.Windows.Media.Brushes.Transparent };
        Grid.SetRow(splitter, 2);
        layout.Children.Add(splitter);
        Grid.SetRow(detail, 3);
        layout.Children.Add(detail);
        Content = layout;

        EventHandler changed = (_, _) => Dispatcher.InvokeAsync(ReloadAsync);
        runtime.SessionsChanged += changed;
        Closed += (_, _) => runtime.SessionsChanged -= changed;
        Loaded += async (_, _) => await ReloadAsync();
        runtime.TrackArtifact("recordings_window");
    }

    private Row? Selected => grid.SelectedItem as Row;

    private static DataGridTextColumn Column(string header, string path, double width) => new()
    {
        Header = header,
        Binding = new System.Windows.Data.Binding(path),
        Width = width > 0 ? new DataGridLength(width) : new DataGridLength(1, DataGridLengthUnitType.Star),
    };

    private async Task ReloadAsync()
    {
        if (loading) { reloadRequested = true; return; }
        loading = true;
        try
        {
            var selected = Selected?.Item.Directory;
            var selectedTab = tabs.SelectedIndex;
            var items = await runtime.LoadSessionsAsync();
            var rows = items.Select(item => new Row(item, runtime.ProcessingStatusFor(item.Directory))).ToList();
            grid.ItemsSource = rows;
            grid.SelectedItem = rows.FirstOrDefault(row => row.Item.Directory == selected) ?? rows.FirstOrDefault();
            tabs.SelectedIndex = selectedTab;
            // Setting the selection shows it: the rows are new, so the selection changes.
            empty.Text = rows.Count == 0
                ? T("No recordings yet. A meeting recorded by hand or by itself shows up here, and so does a file you import.",
                    "Записей пока нет. Здесь появится встреча, записанная вручную или сама, и файл, который вы импортируете.")
                : "";
            empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            detail.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            loading = false;
            if (reloadRequested)
            {
                reloadRequested = false;
                await ReloadAsync();
            }
        }
    }

    private async Task ShowSelectedAsync()
    {
        // Action availability follows the selection immediately, before reading previews.
        ++transcriptShown;
        speakers.Children.Clear();
        if (Selected is not { } row)
        {
            foreach (var button in new[] { finish, retranscribe, listen, folder, delete }) button.IsEnabled = false;
            title.Text = "";
            summary.ShowText("");
            transcript.ShowText("");
            return;
        }
        var item = row.Item;
        var recording = item.Transcript == ProcessingStep.Recording;
        var busy = row.Status?.IsBusy == true;
        var canFinish = item.Transcript is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.SpeakerNames is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.Summary is ProcessingStep.Failed or ProcessingStep.Deferred or ProcessingStep.Stale
            || item.Transcript == ProcessingStep.Pending && item.HasAudio
            || item.Transcript == ProcessingStep.Done && (item.SpeakerNames == ProcessingStep.Pending && runtime.Settings.SpeakerNames.Enabled
                || item.Summary == ProcessingStep.Pending && runtime.Settings.Summary.Enabled);
        finish.IsEnabled = !recording && !busy && canFinish;
        retranscribe.IsEnabled = !recording && item.HasAudio && !busy;
        listen.IsEnabled = item.HasAudio && !recording;
        folder.IsEnabled = true;
        delete.IsEnabled = !recording && !busy;
        var noAudio = T("The audio was not kept for this recording.", "Звук этой записи не сохранён.");
        retranscribe.ToolTip = !item.HasAudio ? noAudio : busy ? row.Status!.Message : null;
        listen.ToolTip = !item.HasAudio ? noAudio : null;
        finish.ToolTip = busy ? row.Status!.Message : !canFinish
            ? T("There is no unfinished processing for this recording.", "Для этой записи нет незавершённой обработки.")
            : T("Try again whatever gave up or is waiting, keeping the transcript and every name typed by hand.",
                "Ещё раз попробовать то, что не получилось или ждёт, — расшифровка и имена, введённые вручную, остаются.");
        title.Text = item.Title;
        problem.Text = item.Problem ?? "";
        problem.Visibility = item.Problem is null ? Visibility.Collapsed : Visibility.Visible;
        processingStatus.Text = row.Status is { IsBusy: true } status ? status.Message : row.TranscriptText;
        if (!item.HasAudio && !recording) processingStatus.Text += "\n" + noAudio;
        if (selectedTranscriptSession != item.Directory)
        {
            selectedTranscriptSession = item.Directory;
            selectedTranscriptKey = null;
        }
        var entries = item.Transcripts ?? [];
        var choices = entries.Select((entry, index) => new TranscriptChoice(entry,
            entry.EngineName + (entries.Count(other => other.Engine == entry.Engine) > 1 ? $" ({index + 1})" : "")
            + " · " + Row.Step(row.StateFor(entry)))).ToList();
        updatingChoices = true;
        engineTabs.ItemsSource = choices.Select(choice => new TabItem { Header = choice.Label, Tag = choice }).ToList();
        engineTabs.SelectedItem = engineTabs.Items.Cast<TabItem>().FirstOrDefault(tab => ((TranscriptChoice)tab.Tag).Key == selectedTranscriptKey)
            ?? engineTabs.Items.Cast<TabItem>().LastOrDefault();
        engineTabs.Visibility = choices.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        tabs.Margin = new Thickness(0, choices.Count > 1 ? 0 : 8, 0, 0);
        updatingChoices = false;
        await ShowTranscriptAsync();
    }

    private async Task ShowTranscriptAsync()
    {
        var version = ++transcriptShown;
        speakers.Children.Clear();
        var item = Selected?.Item;
        if (engineTabs.SelectedItem is not TabItem { Tag: TranscriptChoice choice })
        {
            var emptySummary = item is null ? "" : await ReadAsync(Path.Combine(item.Directory, "summary.md"))
                ?? T("No summary yet.", "Саммари пока нет.");
            if (version != transcriptShown) return;
            transcript.ShowText(T("No transcript yet.", "Расшифровки пока нет."));
            summary.ShowMarkdown(emptySummary);
            speakers.Children.Add(Ui.Detail(T("Speakers appear once there is a transcript.", "Участники появятся, когда будет расшифровка.")));
            return;
        }
        selectedTranscriptKey = choice.Key;
        var directory = choice.Version.Directory;
        if (choice.Version.State != ProcessingStep.Done)
        {
            transcript.ShowText(choice.Label + "\n\n" + (item?.Problem ?? T("Earlier transcripts are available in the tabs above.", "Предыдущие расшифровки доступны во вкладках выше.")));
            summary.ShowText(T("No summary for this transcript yet.", "Саммари этой расшифровки пока нет."));
            speakers.Children.Add(Ui.Detail(T("Speakers appear once this transcript is ready.", "Участники появятся, когда эта расшифровка будет готова.")));
            return;
        }
        var text = await ReadAsync(Path.Combine(directory, "transcript.md")) ?? T("No transcript text available.", "Текст расшифровки недоступен.");
        var summaryText = await ReadAsync(Path.Combine(directory, "summary.md"))
            ?? (item?.Summary == ProcessingStep.Off ? T("Summaries are off.", "Саммари выключены.") : T("No summary yet.", "Саммари пока нет."));
        if (File.Exists(Path.Combine(directory, "summary.stale")))
            summaryText = T("This summary refers to the previous transcript.\n\n", "Это саммари предыдущей расшифровки.\n\n") + summaryText;
        if (version != transcriptShown) return;
        transcript.ShowMarkdown(text);
        summary.ShowMarkdown(summaryText);
        await ShowSpeakersAsync(directory, item?.Title ?? "", version);
    }

    private sealed record TranscriptChoice(TranscriptVersion Version, string Label)
    {
        public string Key => Version.State == ProcessingStep.Done ? $"{Version.Engine}:{Version.CreatedAt:O}" : "pending";
        public override string ToString() => Label;
    }

    private async Task ShowSpeakersAsync(string directory, string meetingTitle, int version)
    {
        var transcriptPath = Path.Combine(directory, "transcript.json");
        if (!File.Exists(transcriptPath))
        {
            speakers.Children.Add(Ui.Detail(T("Speakers appear once there is a transcript.", "Участники появятся, когда будет расшифровка.")));
            return;
        }
        TranscriptDocument? document;
        try { document = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcriptPath)); }
        catch (JsonException) { return; }
        if (document is null) return;
        var file = await SpeakerFile.ReadAsync(directory, CancellationToken.None);
        if (version != transcriptShown) return;
        foreach (var group in document.Segments.Where(segment => segment.Speaker is not null).GroupBy(segment => segment.Speaker!))
        {
            var label = group.Key;
            var row = new Grid { Margin = new Thickness(0, 0, 0, 12) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(110) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.RowDefinitions.Add(new RowDefinition());
            row.RowDefinitions.Add(new RowDefinition());
            var name = Ui.Title(SpeakerLabels.Display(label));
            name.FontWeight = FontWeights.SemiBold;
            name.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(name);
            var (view, box) = Ui.Field(T("name", "имя"), 230);
            box.Text = file.Names.GetValueOrDefault(label) ?? "";
            Grid.SetColumn(view, 1);
            row.Children.Add(view);
            var source = file.Sources.GetValueOrDefault(label) switch
            {
                "manual" => T("by hand · ", "вручную · "),
                "model" => T("model · ", "модель · "),
                "account" => T("your account · ", "ваша учётная запись · "),
                _ => "",
            };
            var count = Ui.Status(source + T($"lines: {group.Count()}", $"реплик: {group.Count()}"));
            count.Margin = new Thickness(12, 0, 0, 0);
            Grid.SetColumn(count, 2);
            row.Children.Add(count);
            var first = Ui.Detail(T("first: ", "первая: ") + group.First().Text.Trim());
            first.TextTrimming = TextTrimming.CharacterEllipsis;
            first.TextWrapping = TextWrapping.NoWrap;
            Grid.SetRow(first, 1);
            Grid.SetColumnSpan(first, 3);
            row.Children.Add(first);
            speakers.Children.Add(row);

            var stored = box.Text;
            async Task CommitAsync()
            {
                if (box.Text.Trim() == stored) return;
                stored = box.Text.Trim();
                try { await runtime.SetSpeakerNameAsync(directory, label, stored, title: meetingTitle); }
                catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
                {
                    Ui.ShowError(this, T("Couldn’t save the name", "Не удалось сохранить имя"), exception.Message);
                }
            }
            box.LostKeyboardFocus += async (_, _) => await CommitAsync();
            box.KeyDown += async (_, args) => { if (args.Key == Key.Enter) await CommitAsync(); };
        }
    }

    private void OpenRetranscribeMenu()
    {
        if (Selected is not { } row) return;
        var settings = runtime.Settings;
        var menu = new ContextMenu { PlacementTarget = retranscribe, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        void Add(string text, string? engine, bool enabled, string? why = null)
        {
            var item = new MenuItem { Header = text, IsEnabled = enabled, ToolTip = why };
            item.Click += async (_, _) =>
            {
                try
                {
                    retranscribe.IsEnabled = false;
                    processingStatus.Text = T("Starting transcription…", "Запускаю расшифровку…");
                    await runtime.RetranscribeAsync(row.Item.Directory, engine);
                    selectedTranscriptKey = "pending";
                    await ReloadAsync();
                }
                catch (Exception exception) when (exception is InvalidOperationException or IOException)
                {
                    Ui.ShowError(this, T("Couldn’t transcribe again", "Не удалось расшифровать заново"), exception.Message);
                    await ReloadAsync();
                }
            };
            menu.Items.Add(item);
        }
        Add(T("With the engine in Settings", "Движком из настроек"), null, true);
        menu.Items.Add(new Separator());
        foreach (var engine in TranscriptionSettings.CloudEngines)
        {
            var hasKey = !string.IsNullOrWhiteSpace(runtime.GetSecret(engine));
            Add(EngineResolver.DisplayName(engine) + T(" — uploads the audio", " — звук уходит в облако"), engine, hasKey,
                hasKey ? null : T("Add a key in Settings first.", "Сначала добавьте ключ в настройках."));
        }
        menu.Items.Add(new Separator());
        foreach (var engine in TranscriptionSettings.LocalEngines)
        {
            var ready = runtime.IsLocalModelReady(engine);
            Add(EngineResolver.DisplayName(engine) + T(" — on this computer", " — на этом компьютере"), engine, ready,
                ready ? null : T("Download the model in Settings first.", "Сначала скачайте модель в настройках."));
        }
        _ = settings;
        menu.IsOpen = true;
    }

    private void Listen(Row row)
    {
        var audio = new[] { "audio.m4a", "mic.wav" }.Select(name => Path.Combine(row.Item.Directory, name)).FirstOrDefault(File.Exists)
                    ?? Directory.EnumerateFiles(row.Item.Directory, "source.*").FirstOrDefault();
        if (audio is null) return;
        runtime.TrackArtifact("session_folder");
        AmanuRuntime.Open(audio);
    }

    private void OpenFolder(Row row)
    {
        runtime.TrackArtifact("session_folder");
        AmanuRuntime.Open(row.Item.Directory);
    }

    private void Delete(Row row)
    {
        var answer = System.Windows.MessageBox.Show(this,
            T($"“{row.Item.Title}” will go to the Recycle Bin with its audio, transcript and summary.",
              $"«{row.Item.Title}» уйдёт в корзину вместе со звуком, расшифровкой и саммари."),
            T("Delete this recording?", "Удалить запись?"), MessageBoxButton.OKCancel, MessageBoxImage.Question, MessageBoxResult.Cancel);
        if (answer != MessageBoxResult.OK) return;
        try { runtime.DeleteSession(row.Item.Directory); }
        catch (Exception exception) when (exception is InvalidOperationException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            Ui.ShowError(this, T("Couldn’t delete the recording", "Не удалось удалить запись"), exception.Message);
        }
    }

    private static async Task<string?> ReadAsync(string path)
    {
        try
        {
            return await File.ReadAllTextAsync(path);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException or IOException or UnauthorizedAccessException)
        {
            // Gone between the list and the click — a re-transcription clears it.
            return null;
        }
    }

    /// <summary>One line of the list, in words.</summary>
    private sealed class Row(SessionListItem item, ProcessingStatus? status)
    {
        public SessionListItem Item { get; } = item;
        public ProcessingStatus? Status { get; } = status;

        public string When => Item.StartedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm", Culture);

        public string Meeting => Item.DurationSeconds > 0
            ? $"{Item.Title} · {Math.Max(1, (int)Math.Round(Item.DurationSeconds / 60.0))} {T("min", "мин")}"
            : Item.Title;

        public ProcessingStep StateFor(TranscriptVersion version) => version.State != ProcessingStep.Done ? Status?.Stage switch
        {
            "transcribing" when Status.IsBusy => ProcessingStep.Transcribing,
            "queued" when Status.IsBusy => ProcessingStep.Pending,
            "deferred" => ProcessingStep.Deferred,
            "failed" => ProcessingStep.Failed,
            _ => version.State,
        } : version.State;

        public string TranscriptText => Item.Transcripts is { Count: > 0 } versions
            ? string.Join("\n", versions.Select(version => $"{version.EngineName} — {Step(StateFor(version))}"))
            : Item.Transcript switch
        {
            ProcessingStep.Done => T("done", "готово") + (Item.Engine is { } engine ? $" ({engine})" : ""),
            ProcessingStep.Recording => T("recording", "идёт запись"),
            ProcessingStep.Off => T("off", "выключено"),
            _ => Step(Status is { IsBusy: true, Stage: "transcribing" } ? ProcessingStep.Transcribing : Item.Transcript),
        };

        public string NamesText => Item.SpeakerCount > 0 ? $"{Item.NamedSpeakerCount}/{Item.SpeakerCount}"
            : Item.Transcript == ProcessingStep.Done ? Step(Item.SpeakerNames) : "";

        public string SummaryText => Status is { IsBusy: true, Stage: "summary" } ? Status.Message
            : Item.Summary == ProcessingStep.Pending && Item.Transcript is ProcessingStep.Pending or ProcessingStep.Transcribing
                ? T("after transcription", "после расшифровки") : Item.Summary switch
        {
            ProcessingStep.Stale => T("out of date", "устарело"),
            _ => Step(Item.Summary),
        };

        public static string Step(ProcessingStep step) => step switch
        {
            ProcessingStep.Done => T("done", "готово"),
            ProcessingStep.Off => T("off", "выключено"),
            ProcessingStep.Failed => T("failed", "не удалось"),
            ProcessingStep.Deferred => T("waiting", "ждёт"),
            ProcessingStep.Transcribing => T("transcribing…", "расшифровывается…"),
            _ => T("queued", "в очереди"),
        };
    }
}
