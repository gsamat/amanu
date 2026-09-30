using System.Diagnostics;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Amanu.App;

/// <summary>A native decoder crash must never take the durable recorder down with it.</summary>
internal sealed class LiveSpeechWorker : IAsyncDisposable
{
    private const string Prefix = "AmanuLive:";
    private readonly Process process;
    private readonly BinaryWriter input;
    private readonly Task errors;
    public string Text { get; private set; } = "";
    public bool Healthy { get; private set; } = true;

    private LiveSpeechWorker(Process process)
    {
        this.process = process;
        input = new BinaryWriter(process.StandardInput.BaseStream);
        errors = DrainErrorsAsync();
    }

    private async Task DrainErrorsAsync()
    {
        var buffer = new char[4096];
        while (await process.StandardError.ReadAsync(buffer).ConfigureAwait(false) != 0) { }
    }

    public static async Task<LiveSpeechWorker> CreateAsync(string runtime, string model, string? language, int threads, CancellationToken token)
    {
        var start = new ProcessStartInfo(Path.Combine(Path.GetDirectoryName(runtime)!, "Amanu.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var argument in new[] { "--live-worker", runtime, model, language ?? "auto", threads.ToString(System.Globalization.CultureInfo.InvariantCulture) })
            start.ArgumentList.Add(argument);
        var process = Process.Start(start) ?? throw new IOException("Could not start the live decoder.");
        // These bounded workers serve live audio deadlines. Background activity
        // such as Windows Update must not starve them at normal priority.
        try { process.PriorityClass = ProcessPriorityClass.AboveNormal; }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException) { }
        var worker = new LiveSpeechWorker(process);
        try { await worker.ReadAsync(token).WaitAsync(TimeSpan.FromMinutes(2), token).ConfigureAwait(false); return worker; }
        catch { await worker.DisposeAsync().ConfigureAwait(false); throw; }
    }

    public async Task FeedAsync(float[] samples, int count, CancellationToken token)
    {
        try
        {
            input.Write((byte)0);
            input.Write(count);
            input.Write(MemoryMarshal.AsBytes(samples.AsSpan(0, count)));
            input.Flush();
            await ReadAsync(token).ConfigureAwait(false);
        }
        catch { Healthy = false; throw; }
    }

    public async Task CommandAsync(byte command, CancellationToken token)
    {
        try { input.Write(command); input.Flush(); await ReadAsync(token).ConfigureAwait(false); }
        catch { Healthy = false; throw; }
    }

    private async Task ReadAsync(CancellationToken token)
    {
        string? line;
        do
        {
            line = await process.StandardOutput.ReadLineAsync(token).ConfigureAwait(false);
            if (line is null) throw new IOException("The live decoder exited unexpectedly.");
        } while (!line.StartsWith(Prefix, StringComparison.Ordinal));
        var answer = JsonSerializer.Deserialize<Reply>(line[Prefix.Length..]) ?? throw new IOException("Empty live response.");
        if (answer.Error is not null) throw new IOException(answer.Error);
        Text = answer.Text;
    }

    public async ValueTask DisposeAsync()
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        await process.WaitForExitAsync().ConfigureAwait(false);
        await errors.ConfigureAwait(false);
        input.Dispose();
        process.Dispose();
    }

    private sealed record Reply(string Text, string? Error = null);

    public static int Main(string[] arguments)
    {
        void ReplyWith(string text, string? error = null)
        {
            Console.WriteLine(Prefix + JsonSerializer.Serialize(new Reply(text, error)));
            Console.Out.Flush();
        }
        try
        {
            using var stream = new LiveSpeechStream(arguments[1], arguments[2], arguments[3] == "auto" ? null : arguments[3], int.Parse(arguments[4]));
            using var reader = new BinaryReader(Console.OpenStandardInput());
            ReplyWith("");
            while (true)
            {
                byte command;
                try { command = reader.ReadByte(); } catch (EndOfStreamException) { return 0; }
                if (command == 0)
                {
                    var count = reader.ReadInt32();
                    if (count is <= 0 or > 35840) throw new InvalidDataException("Invalid live frame.");
                    var samples = new float[count];
                    reader.BaseStream.ReadExactly(MemoryMarshal.AsBytes(samples.AsSpan()));
                    stream.Feed(samples);
                }
                else if (command == 1) stream.FinalizeUtterance();
                else if (command == 2) stream.Begin();
                else return 0;
                ReplyWith(stream.Text);
            }
        }
        catch (Exception exception) { ReplyWith("", exception.Message); return 1; }
    }
}
