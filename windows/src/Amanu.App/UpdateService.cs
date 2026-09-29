using Velopack;
using Velopack.Exceptions;
using Velopack.Sources;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

public enum UpdateOutcome
{
    NotInstalled,
    UpToDate,
    /// <summary>Downloaded and waiting: it installs at the next start, or now through <see cref="UpdateService.RestartIntoUpdate"/>.</summary>
    Ready,
    Busy,
    Failed,
}

public sealed record UpdateResult(UpdateOutcome Outcome, string Message);

/// <summary>
/// The beta channel on GitHub releases. An update is downloaded in the background
/// and never applied while a meeting records or a session is being processed.
/// </summary>
public static class UpdateService
{
    private static UpdateManager? manager;
    private static UpdateInfo? pending;

    private static UpdateManager Manager => manager ??= new UpdateManager(
        new GithubSource("https://github.com/gsamat/amanu", accessToken: null, prerelease: true),
        new UpdateOptions { ExplicitChannel = "beta" });

    public static async Task<UpdateResult> CheckAsync(Func<bool> busy, bool interactive, CancellationToken cancellationToken)
    {
        try
        {
            if (!Manager.IsInstalled)
                return new(UpdateOutcome.NotInstalled, T("This copy of Amanu was not installed by its installer, so it doesn't update itself.",
                    "Эта копия Amanu установлена не установщиком, поэтому сама не обновляется."));
            cancellationToken.ThrowIfCancellationRequested();
            var update = await Manager.CheckForUpdatesAsync();
            if (update is null)
                return new(UpdateOutcome.UpToDate, T($"Amanu {AmanuRuntime.AppVersion} is the latest version.", $"Amanu {AmanuRuntime.AppVersion} — последняя версия."));
            if (busy() && !interactive)
                return new(UpdateOutcome.Busy, T("An update waits until the recording ends.", "Обновление подождёт конца записи."));
            await Manager.DownloadUpdatesAsync(update, progress: null, cancelToken: cancellationToken);
            pending = update;
            return new(UpdateOutcome.Ready, T($"Amanu {update.TargetFullRelease.Version} is downloaded and installs at the next start.",
                $"Amanu {update.TargetFullRelease.Version} скачана и установится при следующем запуске."));
        }
        catch (NotInstalledException)
        {
            return new(UpdateOutcome.NotInstalled, T("This copy of Amanu doesn't update itself.", "Эта копия Amanu сама не обновляется."));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(UpdateOutcome.Failed, "");
        }
        catch (Exception exception)
        {
            // Update failures are retried at the next launch and never get in the way of recording.
            return new(UpdateOutcome.Failed, T("Couldn't check for updates: ", "Не удалось проверить обновления: ") + exception.Message);
        }
    }

    /// <summary>Restarts into the downloaded update — only when nothing is recording or processing.</summary>
    public static bool RestartIntoUpdate(Func<bool> busy)
    {
        if (pending is null || busy()) return false;
        Manager.ApplyUpdatesAndRestart(pending);
        return true;
    }
}
