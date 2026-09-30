using System.Collections.Concurrent;
using System.Diagnostics;
using System.Media;
using System.Text.Json;
using Amanu.App;
using Amanu.Core.Configuration;
using Amanu.Core.Sessions;
using NAudio.Wave;

// --capture <app directory> <data directory> <playback.wav> <output directory>
// Uses the real WASAPI devices, pause, live toggle, and durable TrackWriter.
internal static class CaptureValidation
{
    public static async Task RunAsync(string[] args)
    {
        using var http = new HttpClient();
        var models = new ModelManager(args[1], http, args[0]);
        var settings = new AppSettings();
        settings.LiveTranscription.Enabled = true;
        await using var capture = new WindowsAudioCapture();
        await using var live = new LiveTranscriptionCoordinator(capture, models, () => settings);
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var lines = new ConcurrentDictionary<long, LiveLine>();
        var statuses = new ConcurrentQueue<string>();
        var diagnostics = new ConcurrentQueue<LiveDiagnostic>();
        live.Diagnostic += (_, item) => diagnostics.Enqueue(item);
        var formats = new ConcurrentDictionary<string, string>();
        capture.LiveAudioAvailable += (bool microphone, ReadOnlySpan<byte> data, WaveFormat format, bool silent, long offset) =>
            formats.TryAdd(microphone ? "me" : "them", format.ToString());
        live.LineReady += (_, line) => { lines[line.Id] = line; Console.WriteLine($"{capture.ElapsedMs}ms {line.Speaker}: {line.Text}"); };
        live.StatusChanged += (_, status) =>
        {
            statuses.Enqueue(status);
            Console.WriteLine($"{capture.ElapsedMs}ms STATUS {status}");
            if (status is "live" or "в реальном времени") ready.TrySetResult();
        };
        var store = new SessionStore(args[3], Environment.ProcessId);
        var session = store.Start(DateTimeOffset.Now, "capture validation", SessionTrigger.Manual, null);
        await capture.StartAsync(session, null, CancellationToken.None);
        await ready.Task.WaitAsync(TimeSpan.FromMinutes(2));
        using var playback = new SoundPlayer(args[2]);
        playback.PlayLooping();
        await Task.Delay(20000);
        var pauseAt = capture.ElapsedMs;
        await capture.SetPausedAsync(true, CancellationToken.None);
        await Task.Delay(4000);
        await capture.SetPausedAsync(false, CancellationToken.None);
        var resumeAt = capture.ElapsedMs;
        settings.LiveTranscription.Enabled = false;
        var toggle = Stopwatch.StartNew();
        await live.RefreshAsync();
        var toggleOffMs = toggle.ElapsedMilliseconds;
        settings.LiveTranscription.Enabled = true;
        ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await live.RefreshAsync();
        await ready.Task.WaitAsync(TimeSpan.FromMinutes(2));
        Console.WriteLine($"FAULT WINDOW: parent PID {Environment.ProcessId}; kill only a verified --live-worker child now to check recording survival.");
        await Task.Delay(25000);
        var recordingSurvived = capture.IsRunning;
        playback.Stop();
        var elapsedMs = capture.ElapsedMs;
        var stop = Stopwatch.StartNew();
        var stopped = await capture.StopAsync(CancellationToken.None);
        store.Complete(session, DateTimeOffset.Now, "validation", stopped.MicrophoneOffsetMs, stopped.SystemOffsetMs, 4);
        using var mic = new WaveFileReader(session.MicrophoneTrack);
        using var system = new WaveFileReader(session.SystemTrack);
        var result = new { session.Directory, elapsedMs, stopMs = stop.ElapsedMilliseconds, toggleOffMs, pauseAt, resumeAt,
            recordingSurvived, microphoneSeconds = mic.TotalTime.TotalSeconds, systemSeconds = system.TotalTime.TotalSeconds,
            formats, diagnostics = diagnostics.ToArray(), statuses = statuses.ToArray(), lines = lines.Values.OrderBy(line => line.Id).ToArray() };
        File.WriteAllText(Path.Combine(args[3], "capture-result.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine(JsonSerializer.Serialize(result));
        var unexpectedFailure = args.Length < 5 && statuses.Any(status => status.Contains("stopped") || status.Contains("остановлен"));
        if (!recordingSurvived || lines.Values.Sum(line => line.Text.Length) < 50 || stop.ElapsedMilliseconds > 10000
            || unexpectedFailure
            || mic.TotalTime.TotalMilliseconds < elapsedMs - 2000 || system.TotalTime.TotalMilliseconds < elapsedMs - 2000)
            Environment.ExitCode = 1;
    }
}
