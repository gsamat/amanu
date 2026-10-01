using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using static Amanu.Core.Localization.Localized;
using Block = Markdig.Syntax.Block;
using Inline = Markdig.Syntax.Inlines.Inline;
using List = System.Windows.Documents.List;
using ListItem = System.Windows.Documents.ListItem;
using Table = System.Windows.Documents.Table;
using TableRow = System.Windows.Documents.TableRow;
using TableCell = System.Windows.Documents.TableCell;

namespace Amanu.App;

/// <summary>Selectable native text, without a browser or external image requests.</summary>
internal sealed class MarkdownPreview : RichTextBox
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .DisableHtml().UsePipeTables().UseTaskLists()
        .UseEmphasisExtras(Markdig.Extensions.EmphasisExtras.EmphasisExtraOptions.Strikethrough).Build();
    private static readonly FontFamily CodeFont = new("Cascadia Mono, Consolas");
    private static readonly FontFamily BodyFont = new("Segoe UI");

    public MarkdownPreview()
    {
        IsReadOnly = true;
        IsDocumentEnabled = true;
        FontFamily = BodyFont;
        FontSize = 14;
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        BorderThickness = new Thickness(0);
        SetResourceReference(BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        Padding = new Thickness(0);
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = T("Copy", "Копировать"), Command = ApplicationCommands.Copy, CommandTarget = this });
        menu.Items.Add(new MenuItem { Header = T("Select all", "Выделить всё"), Command = ApplicationCommands.SelectAll, CommandTarget = this });
        ContextMenu = menu;
        ShowText("");
    }

    public void ShowMarkdown(string markdown)
    {
        var document = NewDocument();
        var parsed = Markdown.Parse(markdown, Pipeline);
        foreach (var block in parsed) document.Blocks.Add(RenderBlock(block, markdown));
        Document = document;
        ScrollToHome();
    }

    public void ShowText(string text)
    {
        Document = NewDocument();
        Document.Blocks.Add(new Paragraph(TextRun(text)) { FontFamily = BodyFont, Margin = new Thickness(0) });
        ScrollToHome();
    }

    private static FlowDocument NewDocument()
    {
        var document = new FlowDocument
        {
            FontFamily = BodyFont,
            FontSize = 14,
            PagePadding = new Thickness(12),
            ColumnWidth = double.PositiveInfinity,
        };
        document.SetResourceReference(TextElement.ForegroundProperty, Ui.Primary);
        return document;
    }

    private static System.Windows.Documents.Block RenderBlock(Block block, string source)
    {
        switch (block)
        {
            case HeadingBlock heading:
                var title = Paragraph(heading.Inline);
                title.FontSize = Math.Max(14, 26 - heading.Level * 2);
                title.LineHeight = double.NaN;
                title.FontWeight = FontWeights.SemiBold;
                title.Margin = new Thickness(0, 8, 0, 8);
                return title;
            case ParagraphBlock paragraph:
                return Paragraph(paragraph.Inline);
            case CodeBlock code:
                var codeParagraph = new Paragraph(new Run(code.Lines.ToString()) { FontFamily = CodeFont })
                {
                    FontFamily = CodeFont, FontSize = 13,
                    Padding = new Thickness(8), Margin = new Thickness(0, 0, 0, 8),
                };
                codeParagraph.SetResourceReference(TextElement.BackgroundProperty, "ControlFillColorSecondaryBrush");
                return codeParagraph;
            case ListBlock list:
                var renderedList = new List { MarkerStyle = list.IsOrdered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc,
                    Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(24, 0, 0, 0) };
                if (list.All(item => item is ListItemBlock { Count: > 0 } listItem
                    && listItem[0] is ParagraphBlock { Inline.FirstChild: TaskList }))
                    renderedList.MarkerStyle = TextMarkerStyle.None;
                if (list.IsOrdered && int.TryParse(list.OrderedStart, NumberStyles.None, CultureInfo.InvariantCulture, out var start) && start > 0)
                    renderedList.StartIndex = start;
                foreach (var child in list.OfType<ListItemBlock>())
                {
                    var item = new ListItem { Margin = new Thickness(0, 0, 0, 4) };
                    foreach (var content in child) item.Blocks.Add(RenderBlock(content, source));
                    renderedList.ListItems.Add(item);
                }
                return renderedList;
            case QuoteBlock quote:
                var section = new Section { Padding = new Thickness(12, 0, 0, 0), Margin = new Thickness(0, 0, 0, 8), BorderThickness = new Thickness(3, 0, 0, 0) };
                section.SetResourceReference(System.Windows.Documents.Block.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
                foreach (var content in quote) section.Blocks.Add(RenderBlock(content, source));
                return section;
            case ThematicBreakBlock:
                var rule = new Paragraph { Margin = new Thickness(0, 8, 0, 8), BorderThickness = new Thickness(0, 0, 0, 1) };
                rule.SetResourceReference(System.Windows.Documents.Block.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
                return rule;
            case Markdig.Extensions.Tables.Table table:
                return RenderTable(table, source);
            default:
                // Future syntax remains readable instead of disappearing from a meeting.
                return new Paragraph(TextRun(source.Substring(block.Span.Start, block.Span.Length))) { FontFamily = BodyFont, Margin = new Thickness(0, 0, 0, 8) };
        }
    }

    private static Paragraph Paragraph(ContainerInline? inline)
    {
        var paragraph = new Paragraph { FontFamily = BodyFont, Margin = new Thickness(0, 0, 0, 8), LineHeight = 20 };
        AddInlines(paragraph.Inlines, inline);
        return paragraph;
    }

    private static void AddInlines(InlineCollection target, ContainerInline? container)
    {
        if (container is null) return;
        foreach (var inline in container) AddInline(target, inline);
    }

    // Runs can retain WPF's default serif face when moved into a new document.
    private static Run TextRun(string text) => new(text) { FontFamily = BodyFont };

    private static void AddInline(InlineCollection target, Inline inline)
    {
        switch (inline)
        {
            case LiteralInline literal:
                target.Add(TextRun(literal.Content.ToString()));
                break;
            case LineBreakInline lineBreak:
                target.Add(lineBreak.IsHard ? new LineBreak() : TextRun(" "));
                break;
            case CodeInline code:
                var codeRun = new Run(code.Content) { FontFamily = CodeFont, FontSize = 13 };
                codeRun.SetResourceReference(TextElement.BackgroundProperty, "ControlFillColorSecondaryBrush");
                target.Add(codeRun);
                break;
            case EmphasisInline emphasis:
                var span = new Span();
                if (emphasis.DelimiterChar == '~') span.TextDecorations = TextDecorations.Strikethrough;
                else if (emphasis.DelimiterCount == 2) span.FontWeight = FontWeights.Bold;
                else span.FontStyle = FontStyles.Italic;
                AddInlines(span.Inlines, emphasis);
                target.Add(span);
                break;
            case LinkInline link:
                // A preview never loads image URLs or executes file/custom protocol links.
                if (!link.IsImage && Uri.TryCreate(link.Url, UriKind.Absolute, out var uri)
                    && uri.Scheme is "http" or "https" or "mailto")
                {
                    var hyperlink = new Hyperlink { NavigateUri = uri, ToolTip = uri.AbsoluteUri };
                    AddInlines(hyperlink.Inlines, link);
                    hyperlink.RequestNavigate += (_, args) => { AmanuRuntime.Open(args.Uri.AbsoluteUri); args.Handled = true; };
                    target.Add(hyperlink);
                }
                else AddInlines(target, link);
                break;
            case AutolinkInline link:
                var url = link.IsEmail ? "mailto:" + link.Url : link.Url;
                if (Uri.TryCreate(url, UriKind.Absolute, out var autoUri) && autoUri.Scheme is "http" or "https" or "mailto")
                {
                    var hyperlink = new Hyperlink(TextRun(link.Url)) { NavigateUri = autoUri, ToolTip = url };
                    hyperlink.RequestNavigate += (_, args) => { AmanuRuntime.Open(args.Uri.AbsoluteUri); args.Handled = true; };
                    target.Add(hyperlink);
                }
                else target.Add(TextRun(link.Url));
                break;
            case TaskList task:
                target.Add(TextRun(task.Checked ? "☑" : "☐"));
                break;
            case ContainerInline child:
                AddInlines(target, child);
                break;
        }
    }

    private static Table RenderTable(Markdig.Extensions.Tables.Table table, string source)
    {
        var result = new Table { CellSpacing = 0, Margin = new Thickness(0, 0, 0, 8) };
        var rows = new TableRowGroup();
        result.RowGroups.Add(rows);
        foreach (var row in table.OfType<Markdig.Extensions.Tables.TableRow>())
        {
            var renderedRow = new TableRow();
            rows.Rows.Add(renderedRow);
            var columnIndex = 0;
            foreach (var cell in row.OfType<Markdig.Extensions.Tables.TableCell>())
            {
                var renderedCell = new TableCell { Padding = new Thickness(8, 4, 8, 4), BorderThickness = new Thickness(0, 0, 0, 1),
                    ColumnSpan = cell.ColumnSpan, RowSpan = cell.RowSpan };
                renderedCell.SetResourceReference(TableCell.BorderBrushProperty, "ControlStrokeColorDefaultBrush");
                if (row.IsHeader) renderedCell.FontWeight = FontWeights.SemiBold;
                if (columnIndex < table.ColumnDefinitions.Count)
                    renderedCell.TextAlignment = table.ColumnDefinitions[columnIndex].Alignment switch
                    {
                        TableColumnAlign.Center => TextAlignment.Center,
                        TableColumnAlign.Right => TextAlignment.Right,
                        _ => TextAlignment.Left,
                    };
                foreach (var content in cell) renderedCell.Blocks.Add(RenderBlock(content, source));
                renderedRow.Cells.Add(renderedCell);
                columnIndex += cell.ColumnSpan;
            }
        }
        return result;
    }
}
