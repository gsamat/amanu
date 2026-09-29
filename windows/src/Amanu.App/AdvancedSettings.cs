using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Amanu.Core.Configuration;
using static Amanu.Core.Localization.Localized;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using TextBox = System.Windows.Controls.TextBox;

namespace Amanu.App;

/// <summary>
/// Every setting setup does not ask, drawn from <see cref="SettingsSchema"/>: the
/// window holds no list of its own, so the two cannot drift. Each row is a label,
/// its control, and one line saying what it does; an empty field shows in grey
/// what happens when nothing is set.
/// </summary>
/// <remarks>
/// A value equal to its default is cleared rather than written, and an emptied
/// field means "unset": config.json then reads as the list of the person's own
/// decisions, and a default that improves in a later version still reaches them.
/// </remarks>
internal sealed class AdvancedSettings
{
    private readonly AmanuRuntime runtime;
    private readonly List<Action> refreshers = [];
    private bool refreshing;

    public StackPanel View { get; } = new() { Margin = new Thickness(Ui.Gutter, 20, Ui.Gutter, 16), MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left };

    public AdvancedSettings(AmanuRuntime runtime)
    {
        this.runtime = runtime;
        foreach (var section in SettingsSchema.AdvancedSections)
        {
            var heading = Ui.Heading(section.Title);
            heading.FontSize = 16;
            heading.Margin = new Thickness(0, View.Children.Count == 0 ? 0 : 20, 0, 4);
            View.Children.Add(heading);
            foreach (var entry in section.Entries) View.Children.Add(Row(entry));
        }
        runtime.SettingsChanged += OnSettingsChanged;
        Refresh();
    }

    public void Detach() => runtime.SettingsChanged -= OnSettingsChanged;

    private void OnSettingsChanged(object? sender, EventArgs e) => View.Dispatcher.InvokeAsync(Refresh);

    private void Refresh()
    {
        refreshing = true;
        try { foreach (var refresh in refreshers) refresh(); }
        finally { refreshing = false; }
    }

    private Grid Row(SettingEntry entry)
    {
        var grid = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 240 });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition());

        var label = Ui.Title(entry.Label);
        label.Margin = new Thickness(0, 4, 16, 0);
        grid.Children.Add(label);

        var control = Control(entry);
        control.HorizontalAlignment = HorizontalAlignment.Left;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);

        var help = Ui.Detail(entry.NeedsRestart
            ? entry.Help + " " + T("Takes effect at the next launch.", "Подействует при следующем запуске.")
            : entry.Help);
        help.MaxWidth = 600;
        help.HorizontalAlignment = HorizontalAlignment.Left;
        help.Margin = new Thickness(0, 4, 0, 0);
        Grid.SetRow(help, 1);
        Grid.SetColumnSpan(help, 2);
        grid.Children.Add(help);
        return grid;
    }

    private FrameworkElement Control(SettingEntry entry) => entry.Kind switch
    {
        SettingKind.Toggle => Toggle(entry),
        SettingKind.Choice => Choice(entry),
        SettingKind.Command => Command(entry),
        _ => Text(entry),
    };

    private FrameworkElement Toggle(SettingEntry entry)
    {
        var toggle = Ui.Switch(entry.Label);
        refreshers.Add(() => toggle.IsChecked = runtime.GetValue(entry.Path)?.GetValue<bool>() == true);
        toggle.Click += (_, _) => Commit(entry, JsonValue.Create(toggle.IsChecked == true));
        return toggle;
    }

    private FrameworkElement Choice(SettingEntry entry)
    {
        var combo = new ComboBox { MinWidth = 240, ItemsSource = entry.Options };
        System.Windows.Automation.AutomationProperties.SetName(combo, entry.Label);
        refreshers.Add(() => combo.SelectedItem = runtime.GetValue(entry.Path)?.ToString());
        combo.SelectionChanged += (_, _) =>
        {
            if (!refreshing && combo.SelectedItem is string value) Commit(entry, JsonValue.Create(value));
        };
        return combo;
    }

    private FrameworkElement Text(SettingEntry entry)
    {
        var multiline = entry.Kind is SettingKind.MultilineText or SettingKind.List;
        var (view, box) = Ui.Field(Placeholder(entry), entry.Kind == SettingKind.Number ? 140 : multiline ? 520 : 380, multiline);
        if (entry.Kind == SettingKind.List) box.MinHeight = 90;
        System.Windows.Automation.AutomationProperties.SetName(box, entry.Label);
        refreshers.Add(() =>
        {
            if (box.IsKeyboardFocusWithin) return;
            var value = runtime.GetValue(entry.Path);
            box.Text = Display(entry, value);
        });
        void Leave()
        {
            if (refreshing) return;
            var stored = Display(entry, runtime.GetValue(entry.Path));
            if (box.Text == stored) return;
            switch (Resolve(entry, box.Text))
            {
                case (true, var value):
                    Commit(entry, value);
                    break;
                default:
                    box.Text = stored;
                    break;
            }
        }
        box.LostKeyboardFocus += (_, _) => Leave();
        if (!multiline) box.KeyDown += (_, args) => { if (args.Key == Key.Enter) Leave(); };
        return view;
    }

    /// <summary>The Windows shape of <c>on_stop</c>: a program, and its arguments one per line.</summary>
    private FrameworkElement Command(SettingEntry entry)
    {
        var (programView, program) = Ui.Field(T("program, e.g. C:\\Tools\\sync.exe", "программа, например C:\\Tools\\sync.exe"), 380);
        var (argumentsView, arguments) = Ui.Field(T("arguments, one per line — {session} is the folder", "аргументы по строке — {session} это папка"), 380, multiline: true);
        arguments.MinHeight = 70;
        argumentsView.Margin = new Thickness(0, 6, 0, 0);
        var stack = new StackPanel();
        stack.Children.Add(programView);
        stack.Children.Add(argumentsView);
        refreshers.Add(() =>
        {
            if (stack.IsKeyboardFocusWithin) return;
            var hook = runtime.Settings.OnStop;
            program.Text = hook?.Executable ?? "";
            arguments.Text = string.Join(Environment.NewLine, hook?.Arguments ?? []);
        });
        stack.LostKeyboardFocus += (_, args) =>
        {
            if (refreshing || stack.IsKeyboardFocusWithin) return;
            var executable = program.Text.Trim();
            var value = executable.Length == 0 ? null : JsonSerializer.SerializeToNode(new CommandHook
            {
                Executable = executable,
                Arguments = arguments.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList(),
            }, AppSettings.JsonOptions);
            if (JsonNode.DeepEquals(value, runtime.GetValue(entry.Path))) return;
            Commit(entry, value);
        };
        return stack;
    }

    private string Placeholder(SettingEntry entry) => runtime.DescribeDefault(entry);

    /// <summary>What the field shows: nothing when the value is the default, so the grey default can be read.</summary>
    private string Display(SettingEntry entry, JsonNode? value)
    {
        var fallback = runtime.DefaultFor(entry.Path);
        if (value is null || JsonNode.DeepEquals(value, fallback)) return "";
        return entry.Kind == SettingKind.List && value is JsonArray list
            ? string.Join(Environment.NewLine, list.Select(item => item?.ToString()))
            : value.ToString();
    }

    /// <summary>
    /// A control's contents in the schema's terms: a value to write, null to clear,
    /// or unusable — letters in a number field — which changes nothing.
    /// </summary>
    private static (bool Usable, JsonNode? Value) Resolve(SettingEntry entry, string raw)
    {
        var text = raw.Trim();
        switch (entry.Kind)
        {
            case SettingKind.Number:
                if (text.Length == 0) return (true, null);
                return int.TryParse(text, out var number) && number >= 0 ? (true, JsonValue.Create(number)) : (false, null);
            case SettingKind.List:
                var items = Lines(raw);
                return (true, items.Count == 0 ? null : new JsonArray([.. items.Select(item => (JsonNode)JsonValue.Create(item)!)]));
            default:
                return (true, text.Length == 0 ? null : JsonValue.Create(text));
        }
    }

    private static List<string> Lines(string text) =>
        text.Split(['\r', '\n', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    private void Commit(SettingEntry entry, JsonNode? value)
    {
        if (!Ui.TryUpdate(Ui.OwnerOf(View), () => runtime.SetValue(entry.Path, value))) Refresh();
    }
}
