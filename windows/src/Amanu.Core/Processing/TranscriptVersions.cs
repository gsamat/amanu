using System.Security.Cryptography;
using System.Text.Json;

namespace Amanu.Core.Processing;

public sealed record TranscriptVersion(string Directory, string Engine, DateTimeOffset CreatedAt, ProcessingStep State, bool IsCurrent = false)
{
    public string EngineName => EngineResolver.DisplayName(Engine);
}

/// <summary>Completed transcripts remain readable when another engine is requested.</summary>
public static class TranscriptVersions
{
    public const string RequestFile = "transcribe.requested";

    public static async Task ArchiveCurrentAsync(string directory, CancellationToken cancellationToken = default)
    {
        var path = Path.Combine(directory, "transcript.json");
        if (!File.Exists(path)) return;
        var json = await File.ReadAllBytesAsync(path, cancellationToken).ConfigureAwait(false);
        var id = Convert.ToHexStringLower(SHA256.HashData(json));
        var root = Path.Combine(directory, "transcripts");
        var destination = Path.Combine(root, id);
        if (System.IO.Directory.Exists(destination)) return;
        var staging = Path.Combine(root, "." + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(staging);
        try
        {
            foreach (var name in new[] { "transcript.json", "transcript.md", "speakers.json", "summary.md", "summary.stale" })
            {
                var source = Path.Combine(directory, name);
                if (File.Exists(source)) File.Copy(source, Path.Combine(staging, name));
            }
            cancellationToken.ThrowIfCancellationRequested();
            System.IO.Directory.Move(staging, destination);
        }
        finally
        {
            if (System.IO.Directory.Exists(staging)) System.IO.Directory.Delete(staging, recursive: true);
        }
    }

    public static async Task<IReadOnlyList<TranscriptVersion>> ReadAsync(string directory, CancellationToken cancellationToken = default)
    {
        var versions = new List<TranscriptVersion>();
        var root = Path.Combine(directory, "transcripts");
        if (System.IO.Directory.Exists(root))
            foreach (var archive in System.IO.Directory.EnumerateDirectories(root).Where(path => !Path.GetFileName(path).StartsWith('.')))
                await AddAsync(archive, false).ConfigureAwait(false);
        versions = versions.OrderBy(version => version.CreatedAt).ToList();
        await AddAsync(directory, true).ConfigureAwait(false);
        var requested = Path.Combine(directory, RequestFile);
        if (File.Exists(requested))
        {
            var engine = (await File.ReadAllTextAsync(requested, cancellationToken).ConfigureAwait(false)).Trim();
            var state = File.Exists(Path.Combine(directory, "transcribe.failed")) ? ProcessingStep.Failed
                : File.Exists(Path.Combine(directory, "transcribe.deferred")) ? ProcessingStep.Deferred : ProcessingStep.Pending;
            versions.Add(new TranscriptVersion(directory, engine, File.GetLastWriteTimeUtc(requested), state));
        }
        return versions;

        async Task AddAsync(string path, bool current)
        {
            var transcript = Path.Combine(path, "transcript.json");
            if (!File.Exists(transcript)) return;
            try
            {
                var document = JsonSerializer.Deserialize<TranscriptDocument>(await File.ReadAllTextAsync(transcript, cancellationToken).ConfigureAwait(false));
                if (document is null) return;
                var engine = document.Engine == "local" ? document.Model : document.Engine;
                // A crash after archiving but before replacing the current file must not show it twice.
                if (current)
                {
                    var id = Convert.ToHexStringLower(SHA256.HashData(await File.ReadAllBytesAsync(transcript, cancellationToken).ConfigureAwait(false)));
                    versions.RemoveAll(version => Path.GetFileName(version.Directory) == id);
                }
                versions.Add(new TranscriptVersion(path, engine, document.CreatedAt, ProcessingStep.Done, current));
            }
            catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
            {
                // One broken historical file must not hide the remaining versions.
            }
        }
    }
}
