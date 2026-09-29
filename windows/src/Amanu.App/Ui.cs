using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;
using PasswordBox = System.Windows.Controls.PasswordBox;
using RadioButton = System.Windows.Controls.RadioButton;
using TextBox = System.Windows.Controls.TextBox;

namespace Amanu.App;

/// <summary>
/// The parts every Amanu window is built from, in the macOS app's arrangement: a
/// section is a grey heading over a card; a card holds rows divided by hairlines;
/// a row is an optional control on the left, a title with a line of detail, and
/// whatever sits on the right. One set of measurements, so no two rows that
/// ought to match come out a few pixels apart.
/// </summary>
internal static class Ui
{
    public const double Gutter = 24;
    public const double SectionGap = 28;
    public const double HeaderGap = 8;
    public const double CardGap = 10;
    /// <summary>A switch's width plus its gap: what options under a switched row are indented by.</summary>
    public const double Indent = 56;

    public static readonly string Primary = "TextFillColorPrimaryBrush";
    public static readonly string Secondary = "TextFillColorSecondaryBrush";
    public static readonly string Tertiary = "TextFillColorTertiaryBrush";
    public static readonly string Good = "SystemFillColorSuccessBrush";
    public static readonly string Caution = "SystemFillColorCautionBrush";
    public static readonly string Critical = "SystemFillColorCriticalBrush";

    public static T Brush<T>(this T element, DependencyProperty property, string key) where T : FrameworkElement
    {
        element.SetResourceReference(property, key);
        return element;
    }

    public static TextBlock Title(string text) => new TextBlock
    {
        Text = text,
        FontSize = 14,
        TextWrapping = TextWrapping.Wrap,
    }.Brush(TextBlock.ForegroundProperty, Primary);

    public static TextBlock Detail(string text) => new TextBlock
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 2, 0, 0),
    }.Brush(TextBlock.ForegroundProperty, Secondary);

    public static TextBlock Status(string text = "", string color = "TextFillColorSecondaryBrush") => new TextBlock
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        VerticalAlignment = VerticalAlignment.Center,
    }.Brush(TextBlock.ForegroundProperty, color);

    public static TextBlock Heading(string text) => new TextBlock
    {
        Text = text,
        FontSize = 14,
        FontWeight = FontWeights.SemiBold,
        Margin = new Thickness(0, 0, 0, HeaderGap),
    }.Brush(TextBlock.ForegroundProperty, Primary);

    public static CheckBox Switch(string accessibleName)
    {
        var toggle = new ClickCheckBox();
        toggle.SetResourceReference(FrameworkElement.StyleProperty, "Toggle");
        System.Windows.Automation.AutomationProperties.SetName(toggle, accessibleName);
        return toggle;
    }

    /// <summary>A section: a heading, optionally with a switch before it, over its content.</summary>
    public static FrameworkElement Section(string title, UIElement content, CheckBox? leading = null)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, SectionGap) };
        if (leading is null) stack.Children.Add(Heading(title));
        else
        {
            var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, HeaderGap) };
            leading.Margin = new Thickness(0, 0, 12, 0);
            header.Children.Add(leading);
            var heading = Heading(title);
            heading.Margin = new Thickness(0);
            heading.VerticalAlignment = VerticalAlignment.Center;
            header.Children.Add(heading);
            stack.Children.Add(header);
        }
        stack.Children.Add(content);
        return stack;
    }

    /// <summary>Rows in one card, divided by hairlines.</summary>
    public static Border Box(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (var index = 0; index < rows.Length; index++)
        {
            if (index > 0)
                stack.Children.Add(new Border { Height = 1 }.Brush(Border.BackgroundProperty, "DividerStrokeColorDefaultBrush"));
            stack.Children.Add(rows[index]);
        }
        var box = new Border { Child = stack };
        box.SetResourceReference(FrameworkElement.StyleProperty, "Card");
        return box;
    }

    public static StackPanel Group(double spacing, params UIElement[] items)
    {
        var stack = new StackPanel();
        for (var index = 0; index < items.Length; index++)
        {
            if (items[index] is FrameworkElement element && index > 0)
                element.Margin = new Thickness(element.Margin.Left, element.Margin.Top + spacing, element.Margin.Right, element.Margin.Bottom);
            stack.Children.Add(items[index]);
        }
        return stack;
    }

    /// <summary>
    /// A row: a switch or symbol on the left, the words in the middle, anything
    /// on the right. The label toggles its switch, as a switch's label should.
    /// </summary>
    public static Grid Row(UIElement? leading, TextBlock title, TextBlock? detail = null, params UIElement[] trailing)
    {
        var grid = new Grid { Margin = new Thickness(16, 12, 16, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (leading is FrameworkElement lead)
        {
            lead.Margin = new Thickness(0, 1, 16, 0);
            lead.VerticalAlignment = detail is null ? VerticalAlignment.Center : VerticalAlignment.Top;
            grid.Children.Add(lead);
        }
        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(title);
        if (detail is not null) words.Children.Add(detail);
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        if (leading is CheckBox toggle)
        {
            words.Cursor = Cursors.Hand;
            words.MouseLeftButtonUp += (_, args) =>
            {
                if (args.OriginalSource is Hyperlink or Run { Parent: Hyperlink }) return;
                if (!toggle.IsEnabled) return;
                toggle.IsChecked = toggle.IsChecked != true;
                toggle.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent, toggle));
            };
        }
        if (trailing.Length > 0)
        {
            var right = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
            foreach (var item in trailing)
            {
                if (item is FrameworkElement element && right.Children.Count > 0) element.Margin = new Thickness(8, 0, 0, 0);
                right.Children.Add(item);
            }
            Grid.SetColumn(right, 2);
            grid.Children.Add(right);
        }
        return grid;
    }

    /// <summary>A glyph from Segoe Fluent Icons, in the place a switch would take.</summary>
    public static TextBlock Symbol(string glyph) => new TextBlock
    {
        Text = glyph,
        FontFamily = new System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
        FontSize = 18,
        Width = 40,
        TextAlignment = TextAlignment.Center,
    }.Brush(TextBlock.ForegroundProperty, Secondary);

    /// <remarks>
    /// The title and description sit at the top and everything else at the
    /// bottom, so cards side by side — all as tall as the tallest — line their
    /// buttons and statuses up whatever length their descriptions are.
    /// </remarks>
    public static RadioButton Card(string id, string title, string detail, params UIElement[] accessories)
    {
        var content = new DockPanel { LastChildFill = true };
        var bottom = new StackPanel();
        foreach (var accessory in accessories)
        {
            if (accessory is FrameworkElement element) element.Margin = new Thickness(0, 6, 0, 0);
            bottom.Children.Add(accessory);
        }
        DockPanel.SetDock(bottom, Dock.Bottom);
        content.Children.Add(bottom);
        var top = new StackPanel();
        top.Children.Add(new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }
            .Brush(TextBlock.ForegroundProperty, Primary));
        top.Children.Add(Detail(detail));
        content.Children.Add(top);
        var card = new ClickRadioButton { Tag = id, Content = content };
        card.SetResourceReference(FrameworkElement.StyleProperty, "ChoiceCard");
        System.Windows.Automation.AutomationProperties.SetName(card, title);
        return card;
    }

    /// <summary>Cards side by side, all as tall as the tallest.</summary>
    public static UniformGrid Cards(params RadioButton[] cards)
    {
        var grid = new UniformGrid { Rows = 1, Columns = cards.Length };
        for (var index = 0; index < cards.Length; index++)
        {
            cards[index].Margin = new Thickness(index == 0 ? 0 : CardGap / 2, 0, index == cards.Length - 1 ? 0 : CardGap / 2, 0);
            grid.Children.Add(cards[index]);
        }
        return grid;
    }

    public static TextBlock Link(string text, string url)
    {
        var link = new Hyperlink(new Run(text + " ↗")) { NavigateUri = new Uri(url) };
        link.RequestNavigate += (_, args) =>
        {
            AmanuRuntime.Open(args.Uri.AbsoluteUri);
            args.Handled = true;
        };
        return new TextBlock(link) { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    }

    public static Button Button(string text, Action onClick, bool accent = false)
    {
        var button = new Button { Content = text, Padding = new Thickness(12, 5, 12, 6), MinWidth = 80 };
        if (accent) button.SetResourceReference(FrameworkElement.StyleProperty, "AccentButtonStyle");
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>A text field with the grey words it shows while empty — the default, said as what happens.</summary>
    public static (Grid View, TextBox Box) Field(string placeholder, double width = double.NaN, bool multiline = false)
    {
        var box = new TextBox
        {
            Width = width,
            AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            VerticalScrollBarVisibility = multiline ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled,
            MinHeight = multiline ? 120 : 0,
            MaxHeight = multiline ? 320 : double.PositiveInfinity,
        };
        System.Windows.Automation.AutomationProperties.SetHelpText(box, placeholder);
        var hint = new TextBlock
        {
            Text = placeholder,
            IsHitTestVisible = false,
            Margin = new Thickness(11, multiline ? 7 : 0, 11, 0),
            VerticalAlignment = multiline ? VerticalAlignment.Top : VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            FontSize = 14,
        }.Brush(TextBlock.ForegroundProperty, Tertiary);
        var grid = new Grid { Width = width, HorizontalAlignment = double.IsNaN(width) ? HorizontalAlignment.Stretch : HorizontalAlignment.Left };
        grid.Children.Add(box);
        grid.Children.Add(hint);
        void Update() => hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => Update();
        Update();
        return (grid, box);
    }

    public static (Grid View, PasswordBox Box) Secret(string placeholder, double width = double.NaN)
    {
        var box = new PasswordBox { Width = width };
        System.Windows.Automation.AutomationProperties.SetHelpText(box, placeholder);
        var hint = new TextBlock
        {
            Text = placeholder,
            IsHitTestVisible = false,
            Margin = new Thickness(11, 0, 11, 0),
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 14,
        }.Brush(TextBlock.ForegroundProperty, Tertiary);
        var grid = new Grid { Width = width, HorizontalAlignment = double.IsNaN(width) ? HorizontalAlignment.Stretch : HorizontalAlignment.Left };
        grid.Children.Add(box);
        grid.Children.Add(hint);
        void Update() => hint.Visibility = box.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        box.PasswordChanged += (_, _) => Update();
        Update();
        return (grid, box);
    }

    /// <summary>
    /// Sizes a window to what it wants, but never past the screen it opens on:
    /// at 150% on a 1080p panel the work area is about 670 logical pixels tall,
    /// and a window taller than that opens with its title bar above the screen,
    /// where it cannot be dragged back.
    /// </summary>
    public static void FitToWorkArea(Window window, double width, double height)
    {
        var area = SystemParameters.WorkArea;
        window.Width = Math.Min(width, area.Width - 24);
        window.Height = Math.Min(height, area.Height - 24);
        window.MinWidth = Math.Min(window.MinWidth, window.Width);
        window.MinHeight = Math.Min(window.MinHeight, window.Height);
        window.MaxHeight = area.Height;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = area.Left + (area.Width - window.Width) / 2;
        window.Top = area.Top + Math.Max(0, (area.Height - window.Height) / 2);
    }

    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };

    public static void ShowError(Window? owner, string title, string message) =>
        _ = owner is null
            ? System.Windows.MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Warning)
            : System.Windows.MessageBox.Show(owner, message, title, MessageBoxButton.OK, MessageBoxImage.Warning);

    /// <summary>
    /// Runs a settings change and says why when it could not be made — which, with
    /// config.json unreadable, is by design.
    /// </summary>
    public static bool TryUpdate(Window? owner, Action change)
    {
        try
        {
            change();
            return true;
        }
        catch (Exception exception) when (exception is InvalidOperationException or System.IO.IOException or UnauthorizedAccessException)
        {
            ShowError(owner, Core.Localization.Localized.T("The setting wasn’t saved", "Настройка не сохранена"), exception.Message);
            return false;
        }
    }

    public static Window? OwnerOf(DependencyObject element) => Window.GetWindow(element);

    public static string Megabytes(long bytes) =>
        Core.Localization.Localized.T($"{bytes / 1_000_000:N0} MB", $"{bytes / 1_000_000:N0} МБ");
}
