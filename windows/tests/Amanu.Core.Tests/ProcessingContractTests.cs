using System.Text.Json;
using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class ProcessingContractTests
{
    [Fact]
    public async Task TranscriptWriter_creates_human_and_machine_readable_completion_files()
    {
        using var temp = new TemporaryDirectory();
        var transcript = new TranscriptDocument(
            "assemblyai",
            "universal-3-pro",
            DateTimeOffset.Parse("2026-09-20T12:00:00Z"),
            [new TranscriptSegment(1_500, 4_000, "Привет, мир", "them")]);

        await TranscriptWriter.WriteAsync(temp.Path, "Разговор", transcript,
            new Dictionary<string, string> { ["them"] = "Анна" });

        var markdown = await File.ReadAllTextAsync(Path.Combine(temp.Path, "transcript.md"));
        Assert.Contains("# Разговор", markdown);
        Assert.Contains("engine: assemblyai (universal-3-pro)", markdown);
        Assert.Contains("them → Анна", markdown);
        Assert.Contains("**[0:01] Анна:** Привет, мир", markdown);

        using var json = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(temp.Path, "transcript.json")));
        Assert.Equal("assemblyai", json.RootElement.GetProperty("engine").GetString());
        Assert.Equal(1_500, json.RootElement.GetProperty("segments")[0].GetProperty("start_ms").GetInt64());
    }

    [Theory]
    [InlineData("cloud", true, true, "cloud")]
    [InlineData("cloud", false, true, "unavailable")]
    [InlineData("local", true, true, "local")]
    [InlineData("local", true, false, "cloud")]
    [InlineData("local", false, false, "unavailable")]
    [InlineData("auto", true, true, "cloud-or-local")]
    [InlineData("auto", false, true, "local")]
    public void EngineSelector_matches_the_product_fallback_contract(
        string preference, bool hasCloudKey, bool localSupported, string expected)
    {
        Assert.Equal(expected, EngineSelector.Select(preference, hasCloudKey, localSupported));
    }

    [Fact]
    public void LocalCliResultParser_reads_jsonl_segments()
    {
        const string jsonl = "{\"file\":\"input.wav\",\"text\":\"hello\",\"segments\":[{\"t0_ms\":120,\"t1_ms\":900,\"speaker_id\":\"0\",\"text\":\"hello\"}]}";

        var result = LocalCliResultParser.Parse(jsonl);

        Assert.Equal("hello", result.Text);
        Assert.Collection(result.Segments, segment =>
        {
            Assert.Equal(120, segment.StartMs);
            Assert.Equal(900, segment.EndMs);
            Assert.Equal("0", segment.Speaker);
        });
    }

    [Fact]
    public void LocalCliResultParser_reads_windows_batch_output_with_unescaped_file_path()
    {
        const string jsonl = "{\"file\":\"C:\\Users\\tester\\AppData\\Local\\Temp\\input.wav\",\"text\":\"Привет\",\"segments\":[{\"t0_ms\":100,\"t1_ms\":700,\"text\":\"Привет\"}]}";

        var result = LocalCliResultParser.Parse(jsonl);

        Assert.Equal("Привет", result.Text);
        Assert.Single(result.Segments);
        Assert.Equal(100, result.Segments[0].StartMs);
    }

    [Fact]
    public void ModelCatalog_pins_verified_local_models()
    {
        Assert.Equal("parakeet-tdt-0.6b-v3-Q8_0.gguf", ModelCatalog.Models["parakeet"].FileName);
        Assert.Equal("gigaam-v3-ctc-Q8_0.gguf", ModelCatalog.Models["gigaam"].FileName);
        Assert.Equal("whisper-large-v3-turbo-Q8_0.gguf", ModelCatalog.Models["whisper"].FileName);
    }

    [Theory]
    [InlineData("high", "Это говорит Анна Петрова", "говорит Анна", true)]
    [InlineData("medium", "Это говорит Анна Петрова", "говорит Анна", false)]
    [InlineData("high", "Это говорит Анна Петрова", "другая цитата", false)]
    [InlineData("high", "Анна", "Анна", false)]
    public void SpeakerProposal_requires_high_confidence_and_a_two_word_quote(
        string confidence, string transcript, string quote, bool expected)
    {
        Assert.Equal(expected, SpeakerNameValidator.Accept(confidence, quote, transcript));
    }

    [Fact]
    public void SummaryChunker_preserves_all_text_with_bounded_chunks()
    {
        var text = string.Join("\n", Enumerable.Repeat("строка для резюме", 1_000));

        var chunks = SummaryChunker.Split(text, 500);

        Assert.All(chunks, chunk => Assert.True(chunk.Length <= 500));
        Assert.Equal(text.Replace("\n", ""), string.Concat(chunks).Replace("\n", ""));
    }

    [Fact]
    public void EchoFilter_removes_the_microphone_copy_but_keeps_real_turns()
    {
        var segments = new[]
        {
            new TranscriptSegment(0, 2_000, "Нам нужно выпустить бету", "them"),
            new TranscriptSegment(120, 2_100, "Нам нужно выпустить бету", "me"),
            new TranscriptSegment(2_500, 3_500, "Согласен", "me"),
        };

        var filtered = TranscriptEchoFilter.Filter(segments);

        Assert.Equal(2, filtered.Count);
        Assert.DoesNotContain(filtered, segment => segment.Speaker == "me" && segment.Text.Contains("выпустить"));
        Assert.Contains(filtered, segment => segment.Text == "Согласен");
    }
}
