using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using Amanu.Core.Processing;

namespace Amanu.App;

public sealed record DownloadProgress(string Item, long Received, long Total)
{
    public int Percentage => Total <= 0 ? 0 : (int)Math.Min(100, Received * 100 / Total);
}

public sealed class ModelManager(string dataDirectory, HttpClient httpClient, string? applicationDirectory = null)
{
    public string ModelDirectory { get; } = Path.Combine(dataDirectory, "models");
    public event EventHandler<DownloadProgress>? Progress;
    public event EventHandler<string>? DownloadStarted;
    public event EventHandler<string>? DownloadFinished;
    public event EventHandler<string>? DownloadFailed;

    public string? CliPath
    {
        get
        {
            var path = Path.Combine(applicationDirectory ?? AppContext.BaseDirectory, "local-runtime", "transcribe-cli.exe");
            return File.Exists(path) ? path : null;
        }
    }

    public string ModelPath(string model) => Path.Combine(ModelDirectory, ModelCatalog.Models[model].FileName);
    public bool IsReady(string model) =>
        CliPath is not null && ModelCatalog.Models.ContainsKey(model) && File.Exists(ModelPath(model));

    /// <summary>What the model weighs on this computer, measured rather than quoted; null when it isn't here.</summary>
    public long? DownloadedBytes(string model) =>
        ModelCatalog.Models.ContainsKey(model) && File.Exists(ModelPath(model)) ? new FileInfo(ModelPath(model)).Length : null;

    private readonly HashSet<string> downloading = new(StringComparer.OrdinalIgnoreCase);

    public bool IsDownloading(string model)
    {
        lock (downloading) return downloading.Contains(model);
    }

    public async Task EnsureReadyAsync(string model, CancellationToken cancellationToken = default)
    {
        if (!ModelCatalog.Models.TryGetValue(model, out var artifact))
            throw new InvalidOperationException($"Unknown local model: {model}");
        if (CliPath is null)
            throw new InvalidOperationException("The local transcription runtime is missing from this Amanu installation.");
        Directory.CreateDirectory(ModelDirectory);
        lock (downloading)
        {
            // A second click while the first download runs would fetch the same
            // file into the same place twice.
            if (!downloading.Add(model)) return;
        }
        try
        {
            await DownloadVerifiedAsync($"Model {model}", artifact, ModelPath(model), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            lock (downloading) downloading.Remove(model);
        }
    }

    private async Task DownloadVerifiedAsync(
        string item, DownloadArtifact artifact, string destination, CancellationToken cancellationToken)
    {
        if (File.Exists(destination) && await MatchesHashAsync(destination, artifact.Sha256, cancellationToken).ConfigureAwait(false)) return;
        DownloadStarted?.Invoke(this, item);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            var partial = destination + ".partial";
            // A download that stopped halfway resumes where it stopped, rather than
            // starting the better part of a gigabyte again.
            var have = File.Exists(partial) ? new FileInfo(partial).Length : 0;
            if (have >= artifact.Size) { File.Delete(partial); have = 0; }
            using var request = new HttpRequestMessage(HttpMethod.Get, artifact.Url);
            if (have > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
            using var response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var resumed = have > 0 && response.StatusCode == System.Net.HttpStatusCode.PartialContent;
            if (!resumed) have = 0;
            var total = artifact.Size;
            await using (var input = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
            await using (var output = new FileStream(partial, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 128, true))
            {
                var buffer = new byte[1024 * 128];
                var received = have;
                int read;
                while ((read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    received += read;
                    Progress?.Invoke(this, new DownloadProgress(item, received, total));
                }
            }
            if (!await MatchesHashAsync(partial, artifact.Sha256, cancellationToken).ConfigureAwait(false))
            {
                File.Delete(partial);
                throw new InvalidDataException($"Downloaded {item} did not match its pinned SHA-256 checksum.");
            }
            File.Move(partial, destination, overwrite: true);
            DownloadFinished?.Invoke(this, item);
        }
        catch
        {
            DownloadFailed?.Invoke(this, item);
            throw;
        }
    }

    private static async Task<bool> MatchesHashAsync(string path, string expected, CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexStringLower(hash).Equals(expected, StringComparison.OrdinalIgnoreCase);
    }
}
