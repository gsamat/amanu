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
    private readonly TextBox summary = ReadOnlyText();
    private readonly TextBox transcript = ReadOnlyText();
    private readonly StackPanel speakers = new() { Margin = new Thickness(12) };
    private readonly TextBlock empty = Ui.Detail("");
    private readonly System.Windows.Controls.Button finish;
    private readonly System.Windows.Controls.Button retranscribe;
    private readonly System.Windows.Controls.Button listen;
    private readonly System.Windows.Controls.Button folder;
    private readonly System.Windows.Controls.Button delete;
    private readonly Grid detail = new();
    private bool loading;

    public RecordingsWindow(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        Title = T("Recordings", "Записи");
        Width = 1040;
        Height = 760;
        MinWidth = 760;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = App.WindowIcon;

        grid.Columns.Add(Column(T("When", "Когда"), nameof(Row.When), 140));
        grid.Columns.Add(Column(T("Meeting", "Встреча"), nameof(Row.Meeting), 0));
        grid.Columns.Add(Column(T("Transcript", "Расшифровка"), nameof(Row.TranscriptText), 200));
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

        var tabs = new TabControl { Margin = new Thickness(0, 8, 0, 0) };
        tabs.Items.Add(new TabItem { Header = T("Summary", "Саммари"), Content = summary });
        tabs.Items.Add(new TabItem { Header = T("Transcript", "Расшифровка"), Content = transcript });
        tabs.Items.Add(new TabItem { Header = T("Speakers", "Участники"), Content = Ui.Scroll(speakers) });

        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var button in new[] { finish, retranscribe, listen, folder, delete })
        {
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
        detail.Children.Add(problem);
        Grid.SetRow(tabs, 2);
        detail.Children.Add(tabs);
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

    private static TextBox ReadOnlyText() => new()
    {
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        AcceptsReturn = true,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        BorderThickness = new Thickness(0),
        Padding = new Thickness(12),
        FontSize = 14,
    };

    private async Task ReloadAsync()
    {
        if (loading) return;
        loading = true;
        try
        {
            var selected = Selected?.Item.Directory;
            var items = await runtime.LoadSessionsAsync();
            var rows = items.Select(item => new Row(item)).ToList();
            grid.ItemsSource = rows;
            grid.SelectedItem = rows.FirstOrDefault(row => row.Item.Directory == selected) ?? rows.FirstOrDefault();
            empty.Text = rows.Count == 0
                ? T("No recordings yet. A meeting recorded by hand or by itself shows up here, and so does a file you import.",
                    "Записей пока нет. Здесь появится встреча, записанная вручную или сама, и файл, который вы импортируете.")
                : "";
            empty.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            detail.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            if (grid.SelectedItem is not null) await ShowSelectedAsync();
        }
        finally
        {
            loading = false;
        }
    }

    private async Task ShowSelectedAsync()
    {
        speakers.Children.Clear();
        if (Selected is not { } row)
        {
            title.Text = "";
            summary.Clear();
            transcript.Clear();
            return;
        }
        var item = row.Item;
        title.Text = item.Title;
        problem.Text = item.Problem ?? "";
        problem.Visibility = item.Problem is null ? Visibility.Collapsed : Visibility.Visible;
        summary.Text = await ReadAsync(Path.Combine(item.Directory, "summary.md"))
                       ?? (item.Summary == ProcessingStep.Off ? T("Summaries are off.", "Саммари выключены.") : T("No summary yet.", "Саммари пока нет."));
        if (item.Summary == ProcessingStep.Stale)
            summary.Text = T("This summary is of the previous transcript; a new one is on its way.\n\n", "Это саммари прежней расшифровки; новое на подходе.\n\n") + summary.Text;
        transcript.Text = await ReadAsync(Path.Combine(item.Directory, "transcript.md")) ?? T("No transcript yet.", "Расшифровки пока нет.");
        await ShowSpeakersAsync(item);

        var recording = item.Transcript == ProcessingStep.Recording;
        finish.IsEnabled = !recording && (item.Transcript is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.SpeakerNames is ProcessingStep.Failed or ProcessingStep.Deferred
            || item.Summary is ProcessingStep.Failed or ProcessingStep.Deferred or ProcessingStep.Stale);
        retranscribe.IsEnabled = !recording && item.HasAudio;
        listen.IsEnabled = item.HasAudio && !recording;
        delete.IsEnabled = !recording;
    }

    private async Task ShowSpeakersAsync(SessionListItem item)
    {
        var transcriptPath = Path.Combine(item.Directory, "transcript.json");
        if (!File.Exists(transcriptPath))
        {
            speakers.Children.Add(Ui.Detail(T("Speakers appear once there is a transcript.", "Участники появятся, когда будет расшифровка.")));
            return;
        }
        TranscriptDocument? document;
        try { document = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcriptPath)); }
        catch (JsonException) { return; }
        if (document is null) return;
        var file = await SpeakerFile.ReadAsync(item.Directory, CancellationToken.None);
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
                try { await runtime.SetSpeakerNameAsync(item.Directory, label, stored); }
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
                try { await runtime.RetranscribeAsync(row.Item.Directory, engine); }
                catch (Exception exception) when (exception is InvalidOperationException or IOException)
                {
                    Ui.ShowError(this, T("Couldn’t transcribe again", "Не удалось расшифровать заново"), exception.Message);
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

    private static async Task<string?> ReadAsync(string path) => File.Exists(path) ? await File.ReadAllTextAsync(path) : null;

    /// <summary>One line of the list, in words.</summary>
    private sealed class Row(SessionListItem item)
    {
        public SessionListItem Item { get; } = item;

        public string When => Item.StartedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm", Culture);

        public string Meeting => Item.DurationSeconds > 0
            ? $"{Item.Title} · {Math.Max(1, (int)Math.Round(Item.DurationSeconds / 60.0))} {T("min", "мин")}"
            : Item.Title;

        public string TranscriptText => Item.Transcript switch
        {
            ProcessingStep.Done => T("done", "готово") + (Item.Engine is { } engine ? $" ({engine})" : ""),
            ProcessingStep.Recording => T("recording", "идёт запись"),
            ProcessingStep.Off => T("off", "выключено"),
            _ => Step(Item.Transcript),
        };

        public string NamesText => Item.SpeakerCount > 0 ? $"{Item.NamedSpeakerCount}/{Item.SpeakerCount}"
            : Item.Transcript == ProcessingStep.Done ? Step(Item.SpeakerNames) : "";

        public string SummaryText => Item.Summary switch
        {
            ProcessingStep.Stale => T("out of date", "устарело"),
            _ => Step(Item.Summary),
        };

        private static string Step(ProcessingStep step) => step switch
        {
            ProcessingStep.Done => T("done", "готово"),
            ProcessingStep.Off => T("off", "выключено"),
            ProcessingStep.Failed => T("failed", "не удалось"),
            ProcessingStep.Deferred => T("waiting", "ждёт"),
            _ => T("queued", "в очереди"),
        };
    }
}
