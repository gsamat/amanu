using System.IO;
using System.Net.Http;
using System.Net.Http.Json;
using System.Reflection;
using System.Text.Json;
using Amanu.Core.Analytics;
using Amanu.Core.Configuration;

namespace Amanu.App;

public sealed class AnalyticsService : IAsyncDisposable
{
    private const string Endpoint = "https://stats.amanu.me/api/batch";
    private const string WebsiteId = "8ece1241-c45f-4976-9b20-d7004b2359b8";
    private readonly Func<AppSettings> current;
    private readonly Func<bool> permitted;
    private readonly HttpClient httpClient;
    private readonly string identityPath;
    private readonly string pendingPath;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly CancellationTokenSource lifetime = new();
    private List<PendingEvent> pending = [];
    private Identity identity = new(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow, []);
    private Task? timer;
    /// <summary>Set by the first start to get past the check, so two settings changes at once cannot start twice.</summary>
    private int starting;

    /// <param name="permitted">
    /// False while config.json cannot be read: the file may well say analytics
    /// are off, and nobody can tell, so nothing is sent until it is readable.
    /// </param>
    public AnalyticsService(string dataDirectory, Func<AppSettings> settings, Func<bool> permitted, HttpClient httpClient)
    {
        current = settings;
        this.permitted = permitted;
        this.httpClient = httpClient;
        identityPath = Path.Combine(dataDirectory, "analytics.json");
        pendingPath = Path.Combine(dataDirectory, "analytics-pending.json");
    }

    private AppSettings settings => current();

    private bool Allowed => current().Analytics && permitted();

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(identityPath)!);
        if (!Allowed)
        {
            pending.Clear();
            File.Delete(pendingPath);
            return;
        }
        if (timer is not null || Interlocked.Exchange(ref starting, 1) == 1) return;
        var firstRun = !File.Exists(identityPath);
        identity = await LoadIdentityAsync(cancellationToken).ConfigureAwait(false);
        pending = await LoadPendingAsync(cancellationToken).ConfigureAwait(false);
        if (firstRun) await RecordAsync("installed", cancellationToken: cancellationToken).ConfigureAwait(false);
        var version = AppVersion();
        if (!identity.VersionsSeen.Contains(version, StringComparer.Ordinal))
        {
            identity = identity with { VersionsSeen = [.. identity.VersionsSeen, version] };
            await AtomicFiles.WriteJsonAsync(identityPath, identity, cancellationToken).ConfigureAwait(false);
            await RecordAsync("version_seen", cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        timer = Task.Run(() => TimerAsync(lifetime.Token));
        _ = FlushAsync(lifetime.Token);
    }

    public async Task SetEnabledAsync(bool enabled, CancellationToken cancellationToken = default)
    {
        if (enabled)
        {
            await StartAsync(cancellationToken).ConfigureAwait(false);
        }
        else
        {
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try { pending.Clear(); File.Delete(pendingPath); }
            finally { gate.Release(); }
        }
    }

    public async Task RecordAsync(
        string eventName,
        IReadOnlyDictionary<string, object?>? properties = null,
        CancellationToken cancellationToken = default)
    {
        if (!Allowed || !AnalyticsPolicy.Events.Contains(eventName)) return;
        var data = new Dictionary<string, object?>(PersonProperties(), StringComparer.Ordinal);
        if (properties is not null) foreach (var pair in properties) data[pair.Key] = pair.Value;
        var sanitized = AnalyticsPolicy.Sanitize(data);
        var item = new PendingEvent(Guid.NewGuid().ToString(), eventName, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), sanitized, false, false);
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            pending.RemoveAll(value => DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeSeconds(value.Timestamp) > TimeSpan.FromDays(7));
            pending.Add(item);
            if (pending.Count > 500) pending.RemoveRange(0, pending.Count - 500);
            await SavePendingAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        finally { gate.Release(); }
    }

    private IReadOnlyDictionary<string, object?> PersonProperties()
    {
        var version = Environment.OSVersion.Version;
        return new Dictionary<string, object?>
        {
            ["analytics_schema_version"] = 2,
            ["app_version"] = AppVersion(),
            ["windows_version"] = $"{version.Major}.{version.Minor}.{version.Build}",
            ["arch"] = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
            ["interface_language"] = settings.InterfaceLanguage,
            ["live_transcription"] = settings.LiveTranscription.Enabled,
            ["speaker_names"] = settings.SpeakerNames.Enabled,
            ["auto_record"] = settings.AutoRecord.Enabled ? "mic" : "off",
            ["transcription_engine"] = settings.Transcription.Engine,
            ["transcription_enabled"] = settings.Transcription.Enabled,
            ["transcription_cloud_provider"] = settings.Transcription.Cloud,
            ["summary_backend"] = settings.Summary.Backend,
            ["summary_enabled"] = settings.Summary.Enabled,
            ["speaker_names_backend"] = settings.SpeakerNames.Backend,
            ["keep_audio"] = settings.KeepAudio,
            ["surface"] = "app",
        };
    }

    private async Task TimerAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
                await FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
    }

    public async Task FlushAsync(CancellationToken cancellationToken)
    {
        if (!Allowed) return;
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var selected = pending.Take(250).ToArray();
            if (selected.Length == 0) return;
            var wire = new List<object>();
            var receipts = new List<(string Id, bool Identity)>();
            foreach (var item in selected)
            {
                var basePayload = new Dictionary<string, object?>
                {
                    ["website"] = WebsiteId, ["hostname"] = "app.amanu.me", ["language"] = settings.InterfaceLanguage,
                    ["id"] = identity.Id, ["timestamp"] = item.Timestamp,
                };
                if (!item.IdentityDelivered)
                {
                    wire.Add(new { type = "identify", payload = basePayload });
                    receipts.Add((item.QueueId, true));
                }
                if (!item.EventDelivered)
                {
                    basePayload["url"] = "/"; basePayload["title"] = "Amanu";
                    basePayload["name"] = item.Name; basePayload["data"] = item.Data;
                    wire.Add(new { type = "event", payload = basePayload });
                    receipts.Add((item.QueueId, false));
                }
            }
            if (wire.Count == 0) return;
            using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            requestTimeout.CancelAfter(TimeSpan.FromSeconds(10));
            using var response = await httpClient.PostAsJsonAsync(Endpoint, wire, requestTimeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return;
            var receipt = await response.Content.ReadFromJsonAsync<BatchReceipt>(cancellationToken).ConfigureAwait(false);
            if (receipt is null || receipt.Size != wire.Count || receipt.Processed != wire.Count - receipt.Errors ||
                receipt.Details.Count != receipt.Errors || (receipt.Processed > 0 && string.IsNullOrWhiteSpace(receipt.Cache))) return;
            var rejected = receipt.Details.Select(value => value.Index).ToHashSet();
            if (rejected.Any(index => index < 0 || index >= wire.Count)) return;
            for (var index = 0; index < receipts.Count; index++)
            {
                if (rejected.Contains(index)) continue;
                var target = pending.FindIndex(item => item.QueueId == receipts[index].Id);
                if (target < 0) continue;
                pending[target] = receipts[index].Identity
                    ? pending[target] with { IdentityDelivered = true }
                    : pending[target] with { EventDelivered = true };
            }
            pending.RemoveAll(item => item.IdentityDelivered && item.EventDelivered);
            await SavePendingAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException or JsonException) { }
        finally { gate.Release(); }
    }

    private async Task<Identity> LoadIdentityAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (File.Exists(identityPath))
                return JsonSerializer.Deserialize<Identity>(await File.ReadAllTextAsync(identityPath, cancellationToken).ConfigureAwait(false)) ?? identity;
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException) { }
        try { await AtomicFiles.WriteJsonAsync(identityPath, identity, cancellationToken).ConfigureAwait(false); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        return identity;
    }

    private async Task<List<PendingEvent>> LoadPendingAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (File.Exists(pendingPath))
                return JsonSerializer.Deserialize<List<PendingEvent>>(await File.ReadAllTextAsync(pendingPath, cancellationToken).ConfigureAwait(false)) ?? [];
        }
        catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException) { }
        return [];
    }

    private Task SavePendingAsync(CancellationToken cancellationToken) =>
        AtomicFiles.WriteJsonAsync(pendingPath, pending, cancellationToken);

    private static string AppVersion()
    {
        var value = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        return string.IsNullOrWhiteSpace(value) ? "development" : value.Split('+')[0];
    }

    public async ValueTask DisposeAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(1500));
        try { await FlushAsync(timeout.Token).ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Cancel();
        if (timer is not null) try { await timer.ConfigureAwait(false); } catch (OperationCanceledException) { }
        lifetime.Dispose();
        gate.Dispose();
    }

    private sealed record Identity(string Id, DateTimeOffset CreatedAt, IReadOnlyList<string> VersionsSeen);
    private sealed record PendingEvent(string QueueId, string Name, long Timestamp, IReadOnlyDictionary<string, object> Data, bool IdentityDelivered, bool EventDelivered);
    private sealed record BatchReceipt(int Size, int Processed, int Errors, IReadOnlyList<BatchFailure> Details, string? Cache);
    private sealed record BatchFailure(int Index);
}
