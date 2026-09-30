using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Amanu.App;
using Amanu.Core.Configuration;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class ProcessingHookTests
{
    [Fact]
    public async Task An_open_hook_does_not_block_the_next_session_or_run_twice()
    {
        var root = Path.Combine(Path.GetTempPath(), "amanu-hook-tests", Guid.NewGuid().ToString("N"));
        var sessions = new[] { Path.Combine(root, "first"), Path.Combine(root, "second") };
        foreach (var session in sessions)
        {
            Directory.CreateDirectory(session);
            await File.WriteAllTextAsync(Path.Combine(session, "meta.json"), JsonSerializer.Serialize(new { title = Path.GetFileName(session) }));
        }
        // A viewer stays open until the test releases it, like Notepad opened
        // by on_stop. No network, audio, credentials or user settings are used.
        const string script = "$PID | Set-Content -LiteralPath 'hook.pid'; Add-Content -LiteralPath 'hook.runs' -Value 'started'; "
            + "while (-not (Test-Path -LiteralPath 'release')) { Start-Sleep -Milliseconds 50 }";
        var settings = AppSettings.CreateDefault(root);
        settings.RecordingsDirectory = root;
        settings.Transcription.Enabled = false;
        settings.Analytics = false;
        settings.OnStop = new CommandHook
        {
            Executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            Arguments = ["-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))],
        };
        using var http = new HttpClient();
        await using var analytics = new AnalyticsService(root, () => settings, () => false, http);
        var processor = new ProcessingCoordinator(() => settings, () => true,
            new SecretStore(), new ModelManager(root, http), http, analytics);
        var completed = new ConcurrentDictionary<string, bool>();
        var bothDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var repeated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        processor.StatusChanged += (_, status) =>
        {
            if (status.Stage != "complete" || status.SessionDirectory is null) return;
            if (!completed.TryAdd(status.SessionDirectory, true)) repeated.TrySetResult();
            if (completed.Count == 2) bothDone.TrySetResult();
        };
        try
        {
            processor.Start();
            await bothDone.Task.WaitAsync(TimeSpan.FromSeconds(20));
            foreach (var session in sessions)
            {
                await WaitForFileAsync(Path.Combine(session, "hook.runs"));
                var pid = int.Parse((await File.ReadAllTextAsync(Path.Combine(session, "hook.pid"))).Trim());
                using var hook = Process.GetProcessById(pid);
                Assert.False(hook.HasExited);
                Assert.True(ProcessingCoordinator.Ledger(session).HookRan);
            }
            // Reprocessing a settled session must not launch its hook again.
            processor.Enqueue(sessions[1]);
            await repeated.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Single(await File.ReadAllLinesAsync(Path.Combine(sessions[1], "hook.runs")));
        }
        finally
        {
            foreach (var session in sessions) await File.WriteAllTextAsync(Path.Combine(session, "release"), "release");
            await processor.DisposeAsync();
            foreach (var session in sessions)
            {
                var path = Path.Combine(session, "hook.pid");
                if (!File.Exists(path)) continue;
                var pid = int.Parse((await File.ReadAllTextAsync(path)).Trim());
                try
                {
                    using var hook = Process.GetProcessById(pid);
                    using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    try { await hook.WaitForExitAsync(limit.Token); }
                    catch (OperationCanceledException) { hook.Kill(entireProcessTree: true); await hook.WaitForExitAsync(); }
                }
                catch (ArgumentException) { }
            }
            Directory.Delete(root, recursive: true);
        }
    }

    private static async Task WaitForFileAsync(string path)
    {
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!File.Exists(path)) await Task.Delay(25, limit.Token);
    }
}
