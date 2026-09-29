using System.IO;
using System.Net.Http;
using System.Threading.Channels;
using Amanu.Core.Configuration;
using Amanu.Core.Processing;

namespace Amanu.App;

public sealed class LiveTranscriptionCoordinator : IAsyncDisposable
{
    private readonly AppSettings settings;
    private readonly SecretStore secrets;
    private readonly ModelManager models;
    private readonly HttpClient httpClient;
    private readonly Channel<LiveAudioChunk> chunks = Channel.CreateUnbounded<LiveAudioChunk>();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task worker;

    public LiveTranscriptionCoordinator(
        WindowsAudioCapture capture,
        AppSettings settings,
        SecretStore secrets,
        ModelManager models,
        HttpClient httpClient)
    {
        this.settings = settings;
        this.secrets = secrets;
        this.models = models;
        this.httpClient = httpClient;
        capture.LiveChunkReady += (_, chunk) => chunks.Writer.TryWrite(chunk);
        worker = Task.Run(() => WorkerAsync(lifetime.Token));
    }

    public event EventHandler<string>? TextChanged;

    private async Task WorkerAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var chunk in chunks.Reader.ReadAllAsync(cancellationToken))
            {
                try
                {
                    var audio = new SessionAudio(
                        Path.GetDirectoryName(chunk.MicrophonePath)!, "Live",
                        chunk.MicrophonePath, chunk.SystemPath, null, 0, 0);
                    var result = await TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
                    var text = string.Join(Environment.NewLine, result.Segments.Select(segment =>
                    {
                        var time = TimeSpan.FromMilliseconds(chunk.OffsetMs + segment.StartMs);
                        return $"[{time:mm\\:ss}] {segment.Speaker ?? "speaker"}: {segment.Text}";
                    }));
                    if (!string.IsNullOrWhiteSpace(text)) TextChanged?.Invoke(this, text);
                }
                catch (Exception exception) when (exception is HttpRequestException or InvalidOperationException or InvalidDataException)
                {
                    TextChanged?.Invoke(this, $"Live-транскрипт недоступен: {exception.Message}");
                }
                finally
                {
                    File.Delete(chunk.MicrophonePath);
                    File.Delete(chunk.SystemPath);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    private async Task<TranscriptDocument> TranscribeAsync(SessionAudio audio, CancellationToken cancellationToken)
    {
        var cloudKey = settings.Transcription.Cloud.Equals("openai", StringComparison.OrdinalIgnoreCase)
            ? secrets.Get("openai")
            : secrets.Get("assemblyai");
        var localReady = models.IsReady(settings.Transcription.LocalEngine);
        var selection = EngineSelector.Select(settings.Transcription.Engine, !string.IsNullOrWhiteSpace(cloudKey), localReady);
        if (selection is "cloud" or "cloud-or-local")
        {
            ITranscriptionEngine cloud = settings.Transcription.Cloud.Equals("openai", StringComparison.OrdinalIgnoreCase)
                ? new OpenAiTranscriptionEngine(httpClient, cloudKey!, settings.Transcription.OpenAiModel)
                : new AssemblyAiTranscriptionEngine(httpClient, cloudKey!);
            try { return await cloud.TranscribeAsync(audio, cancellationToken).ConfigureAwait(false); }
            catch (HttpRequestException) when (selection == "cloud-or-local") { }
        }
        if (selection == "local")
            return await new LocalTranscriptionEngine(models, settings.Transcription.LocalEngine, settings.Transcription.Language)
                .TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
        if (selection == "cloud-or-local")
            return await new LocalTranscriptionEngine(models, settings.Transcription.LocalEngine, settings.Transcription.Language)
                .TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
        throw new InvalidOperationException("configure a cloud key or install a local model");
    }

    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel();
        chunks.Writer.TryComplete();
        try { await worker.ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
    }
}
