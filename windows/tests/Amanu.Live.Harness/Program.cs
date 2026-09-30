using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using Amanu.App;
using Amanu.Core.Configuration;
using NAudio.Wave;

if (args[0] == "--capture")
{
    await CaptureValidation.RunAsync(args[1..]);
    return;
}

// Usage: <application directory> <data directory containing models> <mic.wav> <system.wav> [seconds]
// Feeds actual PCM packets at their arrival times through the production coordinator and child decoders.
var appDirectory = args[0];
using var http = new HttpClient();
var models = new ModelManager(args[1], http, appDirectory);
var settings = new AppSettings();
settings.Transcription.Enabled = true;
settings.LiveTranscription.Enabled = true;
var source = new AudioSource();
await using var live = new LiveTranscriptionCoordinator(source, models, () => settings);
var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var lines = new ConcurrentDictionary<long, LiveLine>();
var errors = new ConcurrentQueue<string>();
var maximumLag = 0L;
live.StatusChanged += (_, status) =>
{
    Console.WriteLine($"{source.ElapsedMs}ms STATUS {status}");
    if (status is "live" or "в реальном времени") loaded.TrySetResult();
    if (status.Contains("stopped") || status.Contains("остановлен")) errors.Enqueue(status);
};
live.LineReady += (_, line) =>
{
    lines[line.Id] = line;
    var lag = source.ElapsedMs - line.AudioThroughMs;
    long previous;
    do { previous = Interlocked.Read(ref maximumLag); }
    while (lag > previous && Interlocked.CompareExchange(ref maximumLag, lag, previous) != previous);
    Console.WriteLine($"{source.ElapsedMs}ms TEXT {line.Speaker} id={line.Id} chars={line.Text.Length} queueLag={lag}ms final={line.IsFinal}");
};
using var batchCancellation = new CancellationTokenSource();
var concurrentFinal = args.Length > 6
    ? Task.Run(() => new LocalTranscriptionEngine(models, "parakeet", null).TranscribeAsync(
        new SessionAudio("", "concurrent final validation", args[6], null, null, 0, 0), batchCancellation.Token))
    : null;
if (concurrentFinal is not null) await Task.Delay(3000); // Start a real batch pass before live preempts it.
source.Start();
await loaded.Task.WaitAsync(TimeSpan.FromMinutes(2));
using var mic = new WaveFileReader(args[2]);
using var system = new WaveFileReader(args[3]);
if (mic.WaveFormat.SampleRate != 16000 || mic.WaveFormat.BitsPerSample != 16 || mic.WaveFormat.Channels != 1)
    throw new Exception("Harness input must be 16 kHz mono PCM16.");
var seconds = args.Length > 4 ? int.Parse(args[4]) : (int)mic.TotalTime.TotalSeconds;
var origin = source.ElapsedMs;
var stopwatch = Stopwatch.StartNew();
var micPacket = new byte[320];
var systemPacket = new byte[320];
for (var index = 0; index < seconds * 100; index++)
{
    var due = index * 10L;
    var delay = due - stopwatch.ElapsedMilliseconds;
    if (delay > 0) await Task.Delay((int)delay);
    var micBytes = mic.Read(micPacket, 0, micPacket.Length);
    var systemBytes = system.Read(systemPacket, 0, systemPacket.Length);
    if (micBytes > 0) source.Packet(true, micPacket.AsSpan(0, micBytes), mic.WaveFormat, origin + due);
    if (systemBytes > 0) source.Packet(false, systemPacket.AsSpan(0, systemBytes), system.WaveFormat, origin + due);
    if (errors.Count > 0) break;
}
var stop = Stopwatch.StartNew();
await source.StopAsync();
var stopMs = stop.ElapsedMilliseconds;
var concurrentFinalCancelled = false;
var concurrentFinalSegments = 0;
if (concurrentFinal is not null)
{
    if (args.Length <= 7 || args[7] != "finish") await batchCancellation.CancelAsync();
    try { concurrentFinalSegments = (await concurrentFinal.WaitAsync(TimeSpan.FromMinutes(2))).Segments.Count; }
    catch (OperationCanceledException) { concurrentFinalCancelled = true; }
}
var final = lines.Values.OrderBy(line => line.Id).ToArray();
var result = new { seconds, stopMs, maximumReportedPacketLagMs = maximumLag, concurrentFinalCancelled, concurrentFinalSegments,
    microphoneCharacters = final.Where(line => line.Speaker == "me").Sum(line => line.Text.Length),
    systemCharacters = final.Where(line => line.Speaker == "them").Sum(line => line.Text.Length), errors = errors.ToArray(), lines = final };
var output = args.Length > 5 ? Path.GetFullPath(args[5]) : Path.Combine(Environment.CurrentDirectory, "live-harness-result.json");
File.WriteAllText(output, JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
Console.WriteLine($"RESULT {output} stop={result.stopMs}ms mic={result.microphoneCharacters} system={result.systemCharacters} errors={errors.Count}");
if (errors.Count > 0 || result.microphoneCharacters < 30 || result.systemCharacters < 30 || result.stopMs > 10000)
    Environment.ExitCode = 1;

sealed class AudioSource : ILiveAudioSource
{
    private readonly Stopwatch stopwatch = new();
    public bool IsRunning { get; private set; }
    public long ElapsedMs => stopwatch.ElapsedMilliseconds;
    public event LiveAudioHandler? LiveAudioAvailable;
    public event EventHandler? CaptureStarted;
    public Func<Task>? LiveStopping { get; set; }
    public void Start() { IsRunning = true; stopwatch.Restart(); CaptureStarted?.Invoke(this, EventArgs.Empty); }
    public void Packet(bool microphone, ReadOnlySpan<byte> data, WaveFormat format, long at) => LiveAudioAvailable?.Invoke(microphone, data, format, false, at);
    public async Task StopAsync() { IsRunning = false; if (LiveStopping is { } stop) await stop(); }
}
