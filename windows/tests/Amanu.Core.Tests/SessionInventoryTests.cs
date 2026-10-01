using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class SessionInventoryTests
{
    [Fact]
    public async Task Scan_reads_disk_state_and_orders_newest_first()
    {
        using var temp = new TemporaryDirectory();
        var old = Path.Combine(temp.Path, "20260920-090000-old");
        var latest = Path.Combine(temp.Path, "20260920-100000-latest");
        Directory.CreateDirectory(old);
        Directory.CreateDirectory(latest);
        await File.WriteAllTextAsync(Path.Combine(old, "meta.json"),
            "{\"title\":\"Старый\",\"started_at\":\"2026-09-20T09:00:00Z\",\"duration_seconds\":20,\"trigger\":\"manual\"}");
        await File.WriteAllTextAsync(Path.Combine(latest, "meta.json"),
            "{\"title\":\"Новый\",\"started_at\":\"2026-09-20T10:00:00Z\",\"duration_seconds\":60,\"trigger\":\"auto\"}");
        await File.WriteAllTextAsync(Path.Combine(latest, "transcript.json"), "{\"engine\":\"local\",\"model\":\"parakeet\",\"created_at\":\"2026-09-20T10:02:00Z\",\"segments\":[]}");
        await File.WriteAllTextAsync(Path.Combine(latest, "summary.md"), "# Summary");
        await File.WriteAllBytesAsync(Path.Combine(latest, "audio.m4a"), [1, 2, 3]);

        var sessions = await SessionInventory.ScanAsync(temp.Path);

        Assert.Equal(["Новый", "Старый"], sessions.Select(item => item.Title));
        Assert.Equal(ProcessingStep.Done, sessions[0].Transcript);
        Assert.Equal(ProcessingStep.Done, sessions[0].Summary);
        Assert.True(sessions[0].HasAudio);
        Assert.Equal("local", sessions[0].Engine);
        Assert.Equal(ProcessingStep.Pending, sessions[1].Transcript);
    }
}
