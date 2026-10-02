using System.Reflection;
using Amanu.App;
using Amanu.Core.Configuration;
using Amanu.Core.Localization;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class RecordingQueueTests
{
    [Fact]
    public void First_transcription_shows_active_work_in_the_table()
    {
        var item = Item("meeting", ProcessingStep.Pending, ProcessingStep.Pending);
        var row = Row(item, new("meeting", "transcribing", "Transcribing", true));
        Assert.Equal(Localized.T("transcribing…", "расшифровывается…"), Text(row, "TranscriptText"));
        Assert.Equal(Localized.T("after transcription", "после расшифровки"), Text(row, "SummaryText"));
    }

    [Fact]
    public void Summary_column_shows_the_active_summary_stage()
    {
        var row = Row(Item("meeting", ProcessingStep.Done, ProcessingStep.Pending),
            new("meeting", "summary", "Writing this summary", true));
        Assert.Equal("Writing this summary", Text(row, "SummaryText"));
    }

    [Fact]
    public void An_idle_failed_transcript_is_not_masked_by_an_old_queued_status()
    {
        var version = new TranscriptVersion("meeting", "parakeet", DateTimeOffset.UtcNow, ProcessingStep.Failed);
        var item = Item("meeting", ProcessingStep.Failed, ProcessingStep.Pending) with { Transcripts = [version] };
        var row = Row(item, new("meeting", "queued", "Old queue status", false));
        Assert.Equal("Parakeet v3 — " + Localized.T("failed", "не удалось"), Text(row, "TranscriptText"));
    }

    [Theory]
    [InlineData("failed", ProcessingStep.Failed)]
    [InlineData("deferred", ProcessingStep.Deferred)]
    public void A_terminal_status_remains_visible_when_processing_is_idle(string stage, ProcessingStep expected)
    {
        var version = new TranscriptVersion("meeting", "parakeet", DateTimeOffset.UtcNow, ProcessingStep.Pending);
        var row = Row(Item("meeting", ProcessingStep.Pending, ProcessingStep.Pending),
            new("meeting", stage, "Processing ended", false));
        var actual = (ProcessingStep)row.GetType().GetMethod("StateFor")!.Invoke(row, [version])!;
        Assert.Equal(expected, actual);
    }

    [Fact]
    public async Task Finishing_the_active_session_does_not_reset_its_files()
    {
        await using var fixture = await QueueFixture.CreateAsync();
        fixture.Processor.Start();
        await fixture.Engine.Started.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var marker = Path.Combine(fixture.First, "summary.deferred");
        await File.WriteAllTextAsync(marker, "Preserve while processing");
        var ledger = await File.ReadAllTextAsync(Path.Combine(fixture.First, "processing.json"));
        fixture.Processor.Finish(fixture.First);
        Assert.True(File.Exists(marker));
        Assert.Equal(ledger, await File.ReadAllTextAsync(Path.Combine(fixture.First, "processing.json")));
    }

    [Fact]
    public async Task A_skipped_failed_recording_is_not_left_busy_forever()
    {
        await using var fixture = await QueueFixture.CreateAsync();
        await File.WriteAllTextAsync(Path.Combine(fixture.First, "transcribe.failed"), "Failed recording");
        var drained = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Processor.SessionsChanged += (_, _) => { if (!fixture.Processor.IsBusy) drained.TrySetResult(); };
        fixture.Processor.Enqueue(fixture.First);
        fixture.Processor.Start();
        await drained.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.False(fixture.Processor.StatusFor(fixture.First)?.IsBusy);
    }

    [Fact]
    public async Task A_completed_second_recording_can_be_retranscribed_while_the_first_is_active()
    {
        await using var fixture = await QueueFixture.CreateAsync();
        fixture.Processor.Start();
        await fixture.Engine.Started.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await fixture.Processor.RetranscribeAsync(fixture.Second, "parakeet");
        Assert.Equal("transcribing", fixture.Processor.StatusFor(fixture.First)?.Stage);
        Assert.Equal("queued", fixture.Processor.StatusFor(fixture.Second)?.Stage);
        Assert.Equal("Original second transcript", (await ReadDocumentAsync(fixture.Second)).Segments[0].Text);
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Processor.RetranscribeAsync(fixture.First, "parakeet"));
        var settled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Processor.StatusChanged += (_, status) =>
        {
            if (status.SessionDirectory == fixture.Second && status.Stage == "complete") settled.TrySetResult();
        };
        fixture.Engine.Release.TrySetResult();
        await settled.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal("New transcript", (await ReadDocumentAsync(fixture.Second)).Segments[0].Text);
    }

    private static SessionListItem Item(string directory, ProcessingStep transcript, ProcessingStep summary) =>
        new(directory, "meeting", DateTimeOffset.UtcNow, 1, "manual", null, transcript, ProcessingStep.Off, summary, 0, true);

    private static object Row(SessionListItem item, ProcessingStatus status) => Activator.CreateInstance(
        typeof(RecordingsWindow).GetNestedType("Row", BindingFlags.NonPublic)!, item, status)!;

    private static string Text(object row, string property) => (string)row.GetType().GetProperty(property)!.GetValue(row)!;

    private static async Task<TranscriptDocument> ReadDocumentAsync(string directory) =>
        System.Text.Json.JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(Path.Combine(directory, "transcript.json")))!;

    private sealed class QueueFixture : IAsyncDisposable
    {
        private readonly string root = Path.Combine(Path.GetTempPath(), "amanu-queue-tests", Guid.NewGuid().ToString("N"));
        private readonly HttpClient http = new();
        private AnalyticsService analytics = null!;
        public string First => Path.Combine(root, "recordings", "first");
        public string Second => Path.Combine(root, "recordings", "second");
        public ControlledEngine Engine { get; } = new();
        public ProcessingCoordinator Processor { get; private set; } = null!;
        public static async Task<QueueFixture> CreateAsync()
        {
            var fixture = new QueueFixture();
            var settings = AppSettings.CreateConservative(fixture.root);
            settings.RecordingsDirectory = Path.GetDirectoryName(fixture.First)!;
            settings.Transcription.Engine = "parakeet";
            settings.SpeakerNames.Enabled = false;
            settings.Summary.Enabled = false;
            foreach (var directory in new[] { fixture.First, fixture.Second })
            {
                Directory.CreateDirectory(directory);
                await File.WriteAllTextAsync(Path.Combine(directory, "meta.json"), "{\"title\":\"Queue fixture\"}");
                await File.WriteAllBytesAsync(Path.Combine(directory, "source.wav"), [1]);
                await File.WriteAllTextAsync(Path.Combine(directory, "processing.json"), "{\"transcribe_attempts\":2,\"hook_ran\":true}");
            }
            await TranscriptWriter.WriteAsync(fixture.Second, "second", new("parakeet", "parakeet", DateTimeOffset.UtcNow,
                [new(0, 1000, "Original second transcript", "me")]));
            var models = new ModelManager(fixture.root, fixture.http, fixture.root);
            Directory.CreateDirectory(models.ModelDirectory);
            Directory.CreateDirectory(Path.Combine(fixture.root, "local-runtime"));
            await File.WriteAllBytesAsync(Path.Combine(fixture.root, "local-runtime", "transcribe-cli.exe"), []);
            await File.WriteAllBytesAsync(models.ModelPath("parakeet"), []);
            fixture.analytics = new AnalyticsService(fixture.root, () => settings, () => false, fixture.http);
            fixture.Processor = new(() => settings, () => true, new SecretStore(), models, fixture.http, fixture.analytics,
                (_, _) => fixture.Engine);
            return fixture;
        }
        public async ValueTask DisposeAsync()
        {
            Engine.Release.TrySetResult();
            await Processor.DisposeAsync();
            await analytics.DisposeAsync();
            http.Dispose();
            Directory.Delete(root, true);
        }
    }

    private sealed class ControlledEngine : ITranscriptionEngine
    {
        public string Name => "parakeet";
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
        {
            Started.TrySetResult();
            await Release.Task.WaitAsync(cancellationToken);
            return new("parakeet", "parakeet", DateTimeOffset.UtcNow, [new(0, 1000, "New transcript", "me")]);
        }
    }
}
