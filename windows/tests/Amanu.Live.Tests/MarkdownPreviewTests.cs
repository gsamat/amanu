using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using Amanu.App;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class MarkdownPreviewTests
{
    [Fact]
    public void Existing_transcript_files_render_heading_and_speaker_labels_as_selectable_text() => OnSta(() =>
    {
        var markdown = TranscriptWriter.RenderMarkdown("Встреча", new TranscriptDocument("assemblyai", "universal",
            DateTimeOffset.UtcNow, [new TranscriptSegment(3000, 6000, "Привет, мир.", "me")]),
            new Dictionary<string, string> { ["me"] = "Алиса" });
        var preview = new MarkdownPreview();
        preview.ShowMarkdown(markdown);
        var paragraphs = preview.Document.Blocks.OfType<Paragraph>().ToArray();
        Assert.Equal("Встреча", new TextRange(paragraphs[0].ContentStart, paragraphs[0].ContentEnd).Text.Trim());
        Assert.Equal(FontWeights.SemiBold, paragraphs[0].FontWeight);
        Assert.True(paragraphs[0].FontSize > preview.Document.FontSize);
        var label = Assert.IsType<Span>(paragraphs[2].Inlines.FirstInline);
        Assert.Equal(FontWeights.Bold, label.FontWeight);
        Assert.Equal("[0:03] Алиса:", new TextRange(label.ContentStart, label.ContentEnd).Text);
        Assert.Equal("Segoe UI", label.Inlines.FirstInline.FontFamily.Source);
        preview.SelectAll();
        Assert.Contains("Привет, мир.", preview.Selection.Text);
        Assert.DoesNotContain("**", preview.Selection.Text);
        Assert.DoesNotContain("# Встреча", preview.Selection.Text);
        Assert.True(preview.IsReadOnly);
        Assert.True(preview.IsDocumentEnabled);
    });

    [Fact]
    public void Lists_quotes_code_and_emphasis_preserve_content_and_structure() => OnSta(() =>
    {
        var preview = new MarkdownPreview();
        preview.ShowMarkdown("""
            3. Первый
               - Вложенный *пункт*
            4. Второй

            > Цитата с `кодом` и ~~ошибкой~~.

            ```text
            **это код**, а не жирный текст
            строка 2
            ```

            Строка с переносом.  
            Ещё строка.
            """);
        var list = Assert.IsType<System.Windows.Documents.List>(preview.Document.Blocks.FirstBlock);
        Assert.Equal(3, list.StartIndex);
        Assert.Equal(2, list.ListItems.Count);
        Assert.IsType<System.Windows.Documents.List>(list.ListItems.FirstListItem.Blocks.LastBlock);
        Assert.IsType<Section>(preview.Document.Blocks.ElementAt(1));
        var code = Assert.IsType<Paragraph>(preview.Document.Blocks.ElementAt(2));
        Assert.Contains("**это код**", new TextRange(code.ContentStart, code.ContentEnd).Text);
        Assert.Contains("строка 2", new TextRange(code.ContentStart, code.ContentEnd).Text);
        var last = Assert.IsType<Paragraph>(preview.Document.Blocks.LastBlock);
        Assert.Contains(last.Inlines, inline => inline is LineBreak);
        Assert.Contains("Вложенный пункт", new TextRange(preview.Document.ContentStart, preview.Document.ContentEnd).Text);
    });

    [Fact]
    public void Tables_tasks_and_links_render_without_loading_images_or_activating_custom_protocols() => OnSta(() =>
    {
        var preview = new MarkdownPreview();
        preview.ShowMarkdown("""
            | Участник | Задача |
            | --- | ---: |
            | Алиса | **Проверить** |

            - [x] Готово
            - [ ] Ждёт

            [Сайт](https://example.test/) [Файл](file:///C:/private.txt) ![Диаграмма](https://example.test/image.png)

            <script>сохранить как текст</script>
            """);
        var table = Assert.IsType<Table>(preview.Document.Blocks.FirstBlock);
        Assert.Equal(2, table.RowGroups[0].Rows.Count);
        Assert.Equal(TextAlignment.Right, table.RowGroups[0].Rows[1].Cells[1].TextAlignment);
        var linksParagraph = Assert.IsType<Paragraph>(preview.Document.Blocks.ElementAt(2));
        var link = Assert.Single(linksParagraph.Inlines.OfType<Hyperlink>());
        Assert.Equal("https://example.test/", link.NavigateUri.AbsoluteUri);
        var text = new TextRange(preview.Document.ContentStart, preview.Document.ContentEnd).Text;
        Assert.Contains("☑ Готово", text);
        Assert.Contains("☐ Ждёт", text);
        Assert.Contains("Файл", text);
        Assert.Contains("Диаграмма", text);
        Assert.Contains("<script>сохранить как текст</script>", text);
    });

    [Fact]
    public void Background_and_text_follow_theme_resources_instead_of_the_default_white_editor() => OnSta(() =>
    {
        var preview = new MarkdownPreview();
        preview.Resources["CardBackgroundFillColorDefaultBrush"] = Brushes.Black;
        preview.Resources["TextFillColorPrimaryBrush"] = Brushes.White;
        preview.Resources["AccentTextFillColorPrimaryBrush"] = Brushes.SkyBlue;
        preview.ShowMarkdown("# Заголовок\n\n[Сайт](https://example.test/)");
        Assert.Equal(Brushes.Black, preview.Background);
        Assert.Equal(Brushes.White, preview.Document.Foreground);
        var link = Assert.IsType<Hyperlink>(Assert.IsType<Paragraph>(preview.Document.Blocks.LastBlock).Inlines.FirstInline);
        Assert.Equal(Brushes.SkyBlue, link.Foreground);
        preview.Resources["CardBackgroundFillColorDefaultBrush"] = Brushes.White;
        preview.Resources["TextFillColorPrimaryBrush"] = Brushes.Black;
        preview.Resources["AccentTextFillColorPrimaryBrush"] = Brushes.DarkBlue;
        Assert.Equal(Brushes.White, preview.Background);
        Assert.Equal(Brushes.Black, preview.Document.Foreground);
        Assert.Equal(Brushes.DarkBlue, link.Foreground);
    });

    [Fact]
    public void Switching_documents_removes_old_text_and_keeps_status_messages_literal() => OnSta(() =>
    {
        var preview = new MarkdownPreview();
        preview.ShowMarkdown("# Первый\n\n**Старый текст**");
        preview.SelectAll();
        preview.ShowMarkdown("# Второй\n\nНовый текст");
        var text = new TextRange(preview.Document.ContentStart, preview.Document.ContentEnd).Text;
        Assert.DoesNotContain("Старый", text);
        Assert.Contains("Новый текст", text);
        Assert.True(preview.Selection.IsEmpty);
        preview.ShowText("Ошибка: **не Markdown**");
        Assert.Contains("**не Markdown**", new TextRange(preview.Document.ContentStart, preview.Document.ContentEnd).Text);
    });

    private static void OnSta(Action check)
    {
        Exception? failure = null;
        var thread = new Thread(() => { try { check(); } catch (Exception exception) { failure = exception; } });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(30)), "The Markdown UI check did not finish.");
        if (failure is not null) ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
