using Velopack;
using Velopack.Exceptions;
using Velopack.Sources;

namespace Amanu.App;

public static class UpdateService
{
    public static async Task DownloadPendingUpdateAsync(
        Func<bool> recordingIsActive,
        CancellationToken cancellationToken)
    {
        try
        {
            var manager = new UpdateManager(
                new GithubSource("https://github.com/gsamat/amanu", accessToken: null, prerelease: true),
                new UpdateOptions { ExplicitChannel = "beta" });
            cancellationToken.ThrowIfCancellationRequested();
            var update = await manager.CheckForUpdatesAsync();
            if (update is null || recordingIsActive())
            {
                return;
            }
            await manager.DownloadUpdatesAsync(update, progress: null, cancelToken: cancellationToken);
            // The downloaded update is applied by Velopack on the next clean app start.
        }
        catch (NotInstalledException)
        {
            // Expected when running from Visual Studio or an unpackaged beta folder.
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            // Update failures are retried on the next launch and never block recording.
        }
    }
}
