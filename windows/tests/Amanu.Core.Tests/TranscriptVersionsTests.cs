using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class TranscriptVersionsTests
{
    [Fact]
    public async Task Replacement_keeps_each_engine_and_repeated_runs_with_their_own_names()
    {
        using var temp = new TemporaryDirectory();
        var first = new TranscriptDocument("assemblyai", "universal", DateTimeOffset.UtcNow.AddMinutes(-2),
            [new(0, 1000, "Original words", "A")]);
        await TranscriptWriter.WriteAsync(temp.Path, "Meeting", first, new Dictionary<string, string> { ["A"] = "Alice" });
        await File.WriteAllTextAsync(Path.Combine(temp.Path, "speakers.json"), "{\"names\":{\"A\":\"Alice\"}}");
        await File.WriteAllTextAsync(Path.Combine(temp.Path, "summary.md"), "AssemblyAI summary");
        await TranscriptVersions.ArchiveCurrentAsync(temp.Path);
        await TranscriptVersions.ArchiveCurrentAsync(temp.Path);
        Assert.Single(await TranscriptVersions.ReadAsync(temp.Path));

        var second = first with { Engine = "local", Model = "parakeet", CreatedAt = first.CreatedAt.AddMinutes(1), Segments = [new(0, 1000, "Second words")] };
        await TranscriptWriter.WriteAsync(temp.Path, "Meeting", second);
        await TranscriptVersions.ArchiveCurrentAsync(temp.Path);
        await TranscriptWriter.WriteAsync(temp.Path, "Meeting", second with { CreatedAt = second.CreatedAt.AddMinutes(1), Segments = [new(0, 1000, "Third words")] });
        var versions = await TranscriptVersions.ReadAsync(temp.Path);
        Assert.Equal(["AssemblyAI", "Parakeet v3", "Parakeet v3"], versions.Select(version => version.EngineName));
        Assert.Contains("Alice", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "transcript.md")));
        Assert.Contains("Alice", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "speakers.json")));
        Assert.Equal("AssemblyAI summary", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "summary.md")));
        Assert.Contains("Second words", await File.ReadAllTextAsync(Path.Combine(versions[1].Directory, "transcript.md")));
        Assert.True(versions[2].IsCurrent);
    }

    [Theory]
    [InlineData(null, ProcessingStep.Pending)]
    [InlineData("transcribe.deferred", ProcessingStep.Deferred)]
    [InlineData("transcribe.failed", ProcessingStep.Failed)]
    public async Task Pending_or_failed_second_engine_does_not_hide_completed_transcript(string? marker, ProcessingStep state)
    {
        using var temp = new TemporaryDirectory();
        await File.WriteAllTextAsync(Path.Combine(temp.Path, "meta.json"), "{\"title\":\"Meeting\"}");
        await TranscriptWriter.WriteAsync(temp.Path, "Meeting", new("assemblyai", "universal", DateTimeOffset.UtcNow, [new(0, 1000, "Saved") ]));
        await File.WriteAllTextAsync(Path.Combine(temp.Path, TranscriptVersions.RequestFile), "parakeet");
        if (marker is not null) await File.WriteAllTextAsync(Path.Combine(temp.Path, marker), "Unavailable");
        var session = await SessionInventory.ReadAsync(temp.Path);
        Assert.Equal(state, session.Transcript);
        Assert.Equal([ProcessingStep.Done, state], session.Transcripts!.Select(version => version.State));
        Assert.Equal(["assemblyai", "parakeet"], session.Transcripts!.Select(version => version.Engine));
    }
}
