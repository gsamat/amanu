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

/// <summary>Whether claude and codex are here, and whether they answer when run.</summary>
public static class CliProbe
{
    public static async Task<string> DescribeAsync(string name)
    {
        var path = CommandLineTools.Find(name);
        if (path is null) return T("not installed", "не установлен");
        try
        {
            var start = new ProcessStartInfo(path) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            start.ArgumentList.Add("--version");
            using var process = Process.Start(start);
            if (process is null) return T("installed, doesn’t start", "установлен, но не запускается");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var output = await process.StandardOutput.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            var version = output.Trim().Split('\n')[0].Trim();
            return process.ExitCode == 0
                ? T("answers · ", "отвечает · ") + (version.Length > 40 ? version[..40] : version)
                : T("installed, doesn’t answer", "установлен, но не отвечает");
        }
        catch (Exception exception) when (exception is OperationCanceledException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return T("installed, doesn’t answer", "установлен, но не отвечает");
        }
    }
}
