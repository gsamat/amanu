using System.IO;
using Amanu.Core.Processing;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Amanu.App;

public static class AudioPreprocessor
{
    public static int DurationSeconds(string source)
    {
        try
        {
            using var reader = new AudioFileReader(source);
            return Math.Max(0, (int)Math.Round(reader.TotalTime.TotalSeconds));
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or FormatException or System.Runtime.InteropServices.COMException)
        {
            return 0;
        }
    }

    /// <summary>
    /// Whether a track delivered anything. A device that never produced a buffer
    /// leaves a WAV with a header and no samples; that side is silent, and the
    /// session goes on with the other one.
    /// </summary>
    public static bool HasSamples(string? path)
    {
        if (path is null || !File.Exists(path) || new FileInfo(path).Length <= 64) return false;
        try
        {
            using var reader = new WaveFileReader(path);
            return reader.Length > reader.WaveFormat.BlockAlign * 160;
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or FormatException)
        {
            // A track whose header was never finished — Amanu killed mid-recording —
            // still has its samples; the readers downstream repair what they can.
            return new FileInfo(path).Length > 1024;
        }
    }

    /// <summary>
    /// Makes a WAV whose writer never finished — Amanu killed or the power cut
    /// mid-meeting — say how long it really is, so the samples after the last
    /// header update are not lost to every reader.
    /// </summary>
    public static void RepairHeader(string path)
    {
        if (!File.Exists(path)) return;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        using var reader = new BinaryReader(stream);
        using var writer = new BinaryWriter(stream);
        if (stream.Length < 44 || new string(reader.ReadChars(4)) != "RIFF") return;
        stream.Position = 12;
        var blockAlign = 1;
        while (stream.Position + 8 <= stream.Length)
        {
            var id = new string(reader.ReadChars(4));
            var sizePosition = stream.Position;
            var size = reader.ReadUInt32();
            if (id == "fmt " && size >= 14)
            {
                stream.Position = sizePosition + 4 + 12;
                blockAlign = Math.Max(1, (int)reader.ReadUInt16());
            }
            if (id == "data")
            {
                // Whole frames only: a write cut off mid-frame leaves a tail no reader wants.
                var remaining = Math.Min(uint.MaxValue - 8, stream.Length - (sizePosition + 4));
                var actual = (uint)(remaining - remaining % blockAlign);
                if (actual == size) return;
                stream.Position = sizePosition;
                writer.Write(actual);
                stream.Position = 4;
                writer.Write((uint)Math.Min(uint.MaxValue, stream.Length - 8));
                return;
            }
            stream.Position = sizePosition + 4 + size + (size % 2);
        }
    }

    public static void ConvertToMono16k(string source, string destination)
    {
        using var reader = new AudioFileReader(source);
        WaveFileWriter.CreateWaveFile16(destination, Mono16k(reader));
    }

    /// <summary>
    /// A 16 kHz track cut into pieces of at most <paramref name="seconds"/>, as
    /// `chunk-0000.wav`, `chunk-0001.wav`… in <paramref name="directory"/>, each with
    /// where it starts and ends in the track.
    /// </summary>
    public static IReadOnlyList<(string Path, long StartMs, long EndMs)> Split(string wave, string directory, int seconds)
    {
        using var reader = new WaveFileReader(wave);
        var format = reader.WaveFormat;
        var bytesPerChunk = format.AverageBytesPerSecond * seconds / format.BlockAlign * format.BlockAlign;
        var buffer = new byte[bytesPerChunk];
        var pieces = new List<(string, long, long)>();
        long bytesBefore = 0;
        int read;
        while ((read = reader.Read(buffer, 0, buffer.Length)) > 0)
        {
            var path = Path.Combine(directory, $"chunk-{pieces.Count:0000}.wav");
            using (var writer = new WaveFileWriter(path, format)) writer.Write(buffer, 0, read);
            var start = bytesBefore * 1000 / format.AverageBytesPerSecond;
            bytesBefore += read;
            pieces.Add((path, start, bytesBefore * 1000 / format.AverageBytesPerSecond));
        }
        return pieces;
    }

    private static ISampleProvider Mono16k(ISampleProvider samples)
    {
        if (samples.WaveFormat.Channels == 2)
            samples = new StereoToMonoSampleProvider(samples) { LeftVolume = 0.5f, RightVolume = 0.5f };
        else if (samples.WaveFormat.Channels > 2)
        {
            var mono = new MultiplexingSampleProvider([samples], 1);
            mono.ConnectInputToOutput(0, 0);
            samples = mono;
        }
        if (samples.WaveFormat.SampleRate != 16_000)
            samples = new WdlResamplingSampleProvider(samples, 16_000);
        return samples;
    }

    /// <summary>
    /// Mic on the left, the call on the right, each moved by its start offset so
    /// the two line up. Both sides of a stereo call track are kept — mixed to one
    /// channel, never the left alone — and a missing side is silence of the other
    /// side's length rather than a failure.
    /// </summary>
    public static void CreateAlignedStereo16k(
        string? microphone, string? system, int microphoneOffsetMs, int systemOffsetMs, string destination)
    {
        var micMono = destination + ".mic.wav";
        var systemMono = destination + ".system.wav";
        try
        {
            if (microphone is not null) ConvertToMono16k(microphone, micMono);
            if (system is not null) ConvertToMono16k(system, systemMono);
            using var micReader = microphone is null ? null : new AudioFileReader(micMono);
            using var systemReader = system is null ? null : new AudioFileReader(systemMono);
            var format = WaveFormat.CreateIeeeFloatWaveFormat(16_000, 1);
            var minimum = Math.Min(microphone is null ? systemOffsetMs : microphoneOffsetMs, system is null ? microphoneOffsetMs : systemOffsetMs);
            ISampleProvider Side(AudioFileReader? reader, int offset) => reader is null
                ? new SilenceProvider(format).ToSampleProvider().Take((micReader ?? systemReader)!.TotalTime)
                : new OffsetSampleProvider(reader) { DelayBy = TimeSpan.FromMilliseconds(Math.Max(0, offset - minimum)) };
            var stereo = new MultiplexingSampleProvider([Side(micReader, microphoneOffsetMs), Side(systemReader, systemOffsetMs)], 2);
            stereo.ConnectInputToOutput(0, 0);
            stereo.ConnectInputToOutput(1, 1);
            WaveFileWriter.CreateWaveFile16(destination, stereo);
        }
        finally
        {
            File.Delete(micMono);
            File.Delete(systemMono);
        }
    }

    /// <summary>
    /// Which side each diarized voice was on, from where its words were loudest:
    /// the mic channel or the call channel of the aligned stereo file.
    /// </summary>
    public static IReadOnlyDictionary<string, string> SideByEnergy(string alignedStereo, IReadOnlyList<TranscriptSegment> segments)
    {
        const int frameMs = 100;
        var left = new List<double>();
        var right = new List<double>();
        using (var reader = new AudioFileReader(alignedStereo))
        {
            ISampleProvider samples = reader;
            var frame = reader.WaveFormat.SampleRate * reader.WaveFormat.Channels * frameMs / 1000;
            var buffer = new float[frame];
            int read;
            while ((read = samples.Read(buffer.AsSpan(0, frame))) > 0)
            {
                double l = 0, r = 0;
                for (var index = 0; index + 1 < read; index += 2)
                {
                    l += buffer[index] * buffer[index];
                    r += buffer[index + 1] * buffer[index + 1];
                }
                left.Add(l);
                right.Add(r);
            }
        }
        var totals = new Dictionary<string, (double Mic, double Call)>();
        foreach (var segment in segments)
        {
            var from = (int)Math.Clamp(segment.StartMs / frameMs, 0, left.Count);
            var to = (int)Math.Clamp(segment.EndMs / frameMs + 1, from, left.Count);
            double mic = 0, call = 0;
            for (var index = from; index < to; index++)
            {
                mic += left[index];
                call += right[index];
            }
            var key = segment.Speaker ?? "";
            var current = totals.GetValueOrDefault(key);
            totals[key] = (current.Mic + mic, current.Call + call);
        }
        return totals.ToDictionary(pair => pair.Key,
            pair => pair.Value.Mic > pair.Value.Call ? SpeakerLabels.Me : SpeakerLabels.Them);
    }

    /// <summary>A stereo file's two channels as two mono WAVs.</summary>
    public static void SplitStereo(string source, string left, string right)
    {
        foreach (var (channel, destination) in new[] { (0, left), (1, right) })
        {
            using var reader = new AudioFileReader(source);
            var mono = new MultiplexingSampleProvider([reader], 1);
            mono.ConnectInputToOutput(Math.Min(channel, reader.WaveFormat.Channels - 1), 0);
            WaveFileWriter.CreateWaveFile16(destination, mono);
        }
    }

    public static IReadOnlyList<(string Path, double OffsetSeconds)> SplitWav(string source, string directory, int minutes = 10)
    {
        Directory.CreateDirectory(directory);
        using var reader = new WaveFileReader(source);
        var bytesPerChunk = (long)reader.WaveFormat.AverageBytesPerSecond * minutes * 60;
        bytesPerChunk -= bytesPerChunk % reader.WaveFormat.BlockAlign;
        var parts = new List<(string, double)>();
        var buffer = new byte[reader.WaveFormat.AverageBytesPerSecond];
        var index = 0;
        while (reader.Position < reader.Length)
        {
            var path = Path.Combine(directory, $"part-{index:000}.wav");
            var offset = (double)reader.Position / reader.WaveFormat.AverageBytesPerSecond;
            using var writer = new WaveFileWriter(path, reader.WaveFormat);
            long written = 0;
            while (written < bytesPerChunk)
            {
                var wanted = (int)Math.Min(buffer.Length, bytesPerChunk - written);
                var read = reader.Read(buffer, 0, wanted);
                if (read == 0) break;
                writer.Write(buffer, 0, read);
                written += read;
            }
            parts.Add((path, offset));
            index++;
        }
        return parts;
    }

    /// <summary>
    /// AAC at 48 kHz: Windows' own AAC encoder takes only 44.1 and 48 kHz input,
    /// and refuses the 16 kHz the transcription files are made at.
    /// </summary>
    public static void EncodeAac(string wavePath, string destination)
    {
        using var reader = new WaveFileReader(wavePath);
        var resampled = new WdlResamplingSampleProvider(reader.ToSampleProvider(), 48_000);
        MediaFoundationEncoder.EncodeToAac(new SampleToWaveProvider16(resampled), destination, 128_000);
    }
}
