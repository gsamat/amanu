using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using Amanu.Core.Processing;
using Microsoft.Win32;
using static Amanu.Core.Localization.Localized;

namespace Amanu.App;

public enum KeyVerdict
{
    Works,
    Refused,
    /// <summary>The service could not be asked; the key is kept and tried for real later.</summary>
    Unchecked,
}

/// <summary>
/// Puts a pasted key to the service it is for before it is kept, so a key for one
/// purpose lands in that purpose's slot and a typo is caught while its owner is
/// still looking at the field rather than at the next meeting.
/// </summary>
public static class KeyCheck
{
    public static async Task<(KeyVerdict Verdict, string Message)> CheckAsync(HttpClient client, string service, string key, CancellationToken cancellationToken)
    {
        HttpRequestMessage request = service switch
        {
            SecretNames.AssemblyAi => Get("https://api.assemblyai.com/v2/transcript?limit=1", message => message.Headers.TryAddWithoutValidation("authorization", key)),
            SecretNames.OpenAi => Get("https://api.openai.com/v1/models", message => message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key)),
            SecretNames.ElevenLabs => Get("https://api.elevenlabs.io/v1/user", message => message.Headers.TryAddWithoutValidation("xi-api-key", key)),
            SecretNames.Anthropic => Get("https://api.anthropic.com/v1/models", message =>
            {
                message.Headers.TryAddWithoutValidation("x-api-key", key);
                message.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
            }),
            _ => throw new ArgumentOutOfRangeException(nameof(service)),
        };
        using (request)
        {
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));
                using var response = await client.SendAsync(request, timeout.Token).ConfigureAwait(false);
                var status = (int)response.StatusCode;
                return status switch
                {
                    >= 200 and < 300 => (KeyVerdict.Works, T("key works", "ключ работает")),
                    401 or 403 => (KeyVerdict.Refused, T($"the service refused this key (HTTP {status})", $"сервис не принял этот ключ (HTTP {status})")),
                    _ => (KeyVerdict.Unchecked, T($"saved; the service answered HTTP {status}, so it will be tried with a meeting",
                        $"сохранён; сервис ответил HTTP {status}, ключ проверится на встрече")),
                };
            }
            catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
            {
                return (KeyVerdict.Unchecked, T("saved; couldn’t reach the service to check it", "сохранён; проверить не удалось — сервис недоступен"));
            }
        }
    }

    private static HttpRequestMessage Get(string url, Action<HttpRequestMessage> authorize)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        authorize(request);
        return request;
    }
}

/// <summary>What Windows says about letting desktop apps use the microphone.</summary>
public static class MicrophoneAccess
{
    public enum State { Allowed, DeniedForEveryone, DeniedForDesktopApps, Unknown }

    /// <summary>
    /// Read from the same place Settings › Privacy › Microphone writes. Desktop
    /// apps like Amanu are governed by the "Let desktop apps access your
    /// microphone" switch, the NonPackaged key under the consent store.
    /// </summary>
    public static State Read()
    {
        const string store = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
        try
        {
            string? Value(RegistryKey hive, string path) => hive.OpenSubKey(path)?.GetValue("Value") as string;
            if (Value(Registry.LocalMachine, store) == "Deny" || Value(Registry.CurrentUser, store) == "Deny") return State.DeniedForEveryone;
            if (Value(Registry.CurrentUser, store + @"\NonPackaged") == "Deny") return State.DeniedForDesktopApps;
            return Value(Registry.CurrentUser, store) is null ? State.Unknown : State.Allowed;
        }
        catch (Exception exception) when (exception is System.Security.SecurityException or UnauthorizedAccessException)
        {
            return State.Unknown;
        }
    }

    public static void OpenSettings() => AmanuRuntime.Open("ms-settings:privacy-microphone");
}

public enum CliState { Missing, Broken, SignedOut, Ready }

public sealed record CliStatus(CliState State, string Text);

/// <summary>Whether claude and codex are here, whether they answer when run, and whether anyone is signed in to them.</summary>
public static class CliProbe
{
    public static async Task<CliStatus> ProbeAsync(string name)
    {
        var path = CommandLineTools.Find(name);
        if (path is null) return new(CliState.Missing, T("not installed", "не установлен"));
        var version = await RunAsync(path, ["--version"]);
        if (version is not (0, var output)) return new(CliState.Broken, T("installed, doesn’t answer", "установлен, но не отвечает"));
        // Only an answer that says so counts as signed out. An older CLI without
        // the status command, or one that does not answer in time, is given the
        // benefit of the doubt: the meeting will say plainly if it was wrong.
        if (await RunAsync(path, CommandLineTools.SignInStatusArguments(name)) is (not 0, var status) && CommandLineTools.SaysSignedOut(status))
            return new(CliState.SignedOut, T("installed, but not signed in", "установлен, но вы не вошли"));
        var line = output.Trim().Split('\n')[0].Trim();
        return new(CliState.Ready, T("answers · ", "отвечает · ") + (line.Length > 40 ? line[..40] : line));
    }

    /// <summary>
    /// Runs the tool's own sign-in in a console window of its own, so the link it
    /// prints is there to click if the browser does not open by itself, and waits
    /// for it to finish. On failure the window stays until a key is pressed, so
    /// the reason can be read rather than flashing past.
    /// </summary>
    public static async Task SignInAsync(string name)
    {
        if (CommandLineTools.Find(name) is not { } path) return;
        var start = new ProcessStartInfo("cmd.exe")
        {
            // cmd drops the outer pair of quotes after /c, which leaves the path's own quotes intact.
            Arguments = $"/c \"\"{path}\" {string.Join(' ', CommandLineTools.SignInArguments(name))} || pause\"",
            UseShellExecute = false,
            CreateNoWindow = false,
        };
        try
        {
            using var process = Process.Start(start);
            if (process is not null) await process.WaitForExitAsync();
        }
        catch (System.ComponentModel.Win32Exception)
        {
        }
    }

    /// <summary>The exit code and everything printed, or null when it would not start or took more than 15 seconds.</summary>
    private static async Task<(int ExitCode, string Output)?> RunAsync(string path, IReadOnlyList<string> arguments)
    {
        try
        {
            var start = new ProcessStartInfo(path)
            {
                UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
            };
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = Process.Start(start);
            if (process is null) return null;
            process.StandardInput.Close();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            try
            {
                var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
                var error = process.StandardError.ReadToEndAsync(timeout.Token);
                await process.WaitForExitAsync(timeout.Token);
                return (process.ExitCode, await output + await error);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return null;
            }
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or System.IO.IOException)
        {
            return null;
        }
    }
}
