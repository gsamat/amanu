using Amanu.App;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class RetranscriptionTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Second_engine_publishes_progress_and_keeps_original_until_success(bool fail)
    {
        var root = Path.Combine(Path.GetTempPath(), "amanu-retranscription-tests", Guid.NewGuid().ToString("N"));
        var directory = Path.Combine(root, "recordings", "meeting");
        Directory.CreateDirectory(directory);
        var settings = AppSettings.CreateConservative(root);
        settings.RecordingsDirectory = Path.GetDirectoryName(directory)!;
        settings.Transcription.Enabled = false; // An explicit request still runs.
        settings.Transcription.Engine = "whisper";
        settings.KeepAudio = true;
        settings.SpeakerNames.Enabled = false;
        await File.WriteAllTextAsync(Path.Combine(directory, "meta.json"), "{\"title\":\"Test meeting\"}");
        await File.WriteAllBytesAsync(Path.Combine(directory, "source.wav"), [1]); // Fake engine never reads it.
        var original = new TranscriptDocument("assemblyai", "universal", DateTimeOffset.UtcNow.AddMinutes(-1), [new(0, 1000, "AssemblyAI words", "A")]);
        await TranscriptWriter.WriteAsync(directory, "Test meeting", original);
        await SpeakerFile.WriteAsync(directory, new Dictionary<string, string> { ["A"] = "Alice" }, new Dictionary<string, string> { ["A"] = "model" }, CancellationToken.None);
        await File.WriteAllTextAsync(Path.Combine(directory, "summary.md"), "Original summary");
        var engine = new ControlledEngine(fail);
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        var models = new ModelManager(root, http, root);
        Directory.CreateDirectory(models.ModelDirectory);
        Directory.CreateDirectory(Path.Combine(root, "local-runtime"));
        await File.WriteAllBytesAsync(Path.Combine(root, "local-runtime", "transcribe-cli.exe"), []);
        await File.WriteAllBytesAsync(models.ModelPath("parakeet"), []);
        var processor = new ProcessingCoordinator(() => settings, () => true, new SecretStore(), models, http, analytics,
            (model, _) => { Assert.Equal("parakeet", model); return engine; });
        var settled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var updates = 0;
        processor.SessionsChanged += (_, _) => Interlocked.Increment(ref updates);
        processor.StatusChanged += (_, status) => { if (status.Stage == (fail ? "deferred" : "complete")) settled.TrySetResult(); };
        try
        {
            await processor.RetranscribeAsync(directory, "parakeet");
            Assert.Equal("queued", processor.StatusFor(directory)?.Stage);
            Assert.True(updates > 0);
            Assert.Equal(original.Engine, (await ReadDocumentAsync(directory)).Engine);
            Assert.Equal(original.CreatedAt, (await ReadDocumentAsync(directory)).CreatedAt);
            Assert.False(File.Exists(Path.Combine(directory, "summary.stale")));
            await Assert.ThrowsAsync<InvalidOperationException>(() => processor.RetranscribeAsync(directory, "whisper"));
            processor.Start();
            await engine.Started.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal("transcribing", processor.StatusFor(directory)?.Stage);
            Assert.Contains("AssemblyAI words", await File.ReadAllTextAsync(Path.Combine(directory, "transcript.md")));
            Assert.Contains("Alice", await File.ReadAllTextAsync(Path.Combine(directory, "speakers.json")));
            engine.Release.TrySetResult();
            await settled.Task.WaitAsync(TimeSpan.FromSeconds(10));
            var versions = await TranscriptVersions.ReadAsync(directory);
            Assert.Equal(2, versions.Count);
            Assert.Equal("assemblyai", versions[0].Engine);
            Assert.Equal("parakeet", versions[1].Engine);
            Assert.Equal(fail ? ProcessingStep.Deferred : ProcessingStep.Done, versions[1].State);
            Assert.Equal(fail, File.Exists(Path.Combine(directory, TranscriptVersions.RequestFile)));
            Assert.Equal(!fail, File.Exists(Path.Combine(directory, "summary.stale")));
            Assert.Equal(fail ? "assemblyai" : "parakeet", (await ReadDocumentAsync(directory)).Engine);
            if (!fail)
            {
                Assert.Contains("Alice", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "speakers.json")));
                await processor.SetSpeakerNameAsync(versions[0].Directory, "A", "Archived name", title: "Test meeting");
                await processor.SetSpeakerNameAsync(directory, "0", "Current name");
                Assert.Contains("Archived name", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "transcript.md")));
                Assert.DoesNotContain("Current name", await File.ReadAllTextAsync(Path.Combine(versions[0].Directory, "transcript.md")));
                Assert.Contains("Current name", await File.ReadAllTextAsync(Path.Combine(directory, "transcript.md")));
                Assert.DoesNotContain("Archived name", await File.ReadAllTextAsync(Path.Combine(directory, "transcript.md")));
            }
        }
        finally
        {
            engine.Release.TrySetResult();
            await processor.DisposeAsync();
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task<TranscriptDocument> ReadDocumentAsync(string directory) =>
        System.Text.Json.JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(Path.Combine(directory, "transcript.json")))!;

    private sealed class ControlledEngine(bool fail) : ITranscriptionEngine
    {
        public string Name => "parakeet";
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
        {
            Started.TrySetResult();
            await Release.Task.WaitAsync(cancellationToken);
            if (fail) throw new ProcessingFailure(FailureKind.Environmental, "Test engine unavailable");
            return new("parakeet", "parakeet", DateTimeOffset.UtcNow, [new(0, 1000, "Parakeet words", "0")]);
        }
    }
}
