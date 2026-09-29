using System.IO;
using System.Threading.Channels;
using Amanu.Core.Processing;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

/// <summary>
/// Transcribes the recording in 20-second pieces while it runs. A local model is
/// preferred when there is one, so the pieces stay on this computer; with only a
/// cloud engine configured they go where the final transcript would go anyway.
/// </summary>
public sealed class LiveTranscriptionCoordinator : IAsyncDisposable
{
    private readonly Func<ITranscriptionEngine?> engine;
    private readonly Channel<LiveAudioChunk> chunks = Channel.CreateUnbounded<LiveAudioChunk>();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task worker;

    public LiveTranscriptionCoordinator(WindowsAudioCapture capture, Func<ITranscriptionEngine?> engine)
    {
        this.engine = engine;
        capture.LiveChunkReady += (_, chunk) => chunks.Writer.TryWrite(chunk);
        worker = Task.Run(() => WorkerAsync(lifetime.Token));
    }

    /// <summary>One line of live transcript: when, who, what.</summary>
    public event EventHandler<LiveLine>? LineReady;
    public event EventHandler<string>? StatusChanged;

    private async Task WorkerAsync(CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var chunk in chunks.Reader.ReadAllAsync(cancellationToken))
            {
                try
                {
                    var selected = engine();
                    if (selected is null)
                    {
                        StatusChanged?.Invoke(this, T("no engine for a live transcript", "нет движка для расшифровки на ходу"));
                        continue;
                    }
                    StatusChanged?.Invoke(this, EngineResolver.DisplayName(selected.Name));
                    var audio = new SessionAudio(Path.GetDirectoryName(chunk.MicrophonePath)!, "Live",
                        AudioPreprocessor.HasSamples(chunk.MicrophonePath) ? chunk.MicrophonePath : null,
                        AudioPreprocessor.HasSamples(chunk.SystemPath) ? chunk.SystemPath : null, null, 0, 0);
                    if (!audio.HasAudio) continue;
                    var result = await selected.TranscribeAsync(audio, cancellationToken).ConfigureAwait(false);
                    foreach (var segment in result.Segments.Where(segment => !string.IsNullOrWhiteSpace(segment.Text)))
                        LineReady?.Invoke(this, new LiveLine(TimeSpan.FromMilliseconds(chunk.OffsetMs + segment.StartMs),
                            segment.Speaker ?? "", segment.Text.Trim()));
                }
                catch (Exception exception) when (exception is ProcessingFailure or IOException or InvalidDataException)
                {
                    StatusChanged?.Invoke(this, T("live transcript paused: ", "расшифровка на ходу приостановлена: ") + exception.Message);
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

    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        chunks.Writer.TryComplete();
        try { await worker.ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
    }
}

public sealed record LiveLine(TimeSpan At, string Speaker, string Text);
