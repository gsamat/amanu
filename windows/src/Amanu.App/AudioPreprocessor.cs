using System.IO;
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
        catch { return 0; }
    }

    public static void ConvertToMono16k(string source, string destination)
    {
        using var reader = new AudioFileReader(source);
        ISampleProvider samples = reader;
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
        WaveFileWriter.CreateWaveFile16(destination, samples);
    }

    public static void CreateAlignedStereo16k(
        string microphone, string system, int microphoneOffsetMs, int systemOffsetMs, string destination)
    {
        var micMono = destination + ".mic.wav";
        var systemMono = destination + ".system.wav";
        try
        {
            ConvertToMono16k(microphone, micMono);
            ConvertToMono16k(system, systemMono);
            using var micReader = new AudioFileReader(micMono);
            using var systemReader = new AudioFileReader(systemMono);
            var minimum = Math.Min(microphoneOffsetMs, systemOffsetMs);
            ISampleProvider mic = new OffsetSampleProvider(micReader)
            {
                DelayBy = TimeSpan.FromMilliseconds(Math.Max(0, microphoneOffsetMs - minimum)),
            };
            ISampleProvider other = new OffsetSampleProvider(systemReader)
            {
                DelayBy = TimeSpan.FromMilliseconds(Math.Max(0, systemOffsetMs - minimum)),
            };
            var stereo = new MultiplexingSampleProvider([mic, other], 2);
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

    public static void MixStereoToMono16k(string stereoSource, string destination) =>
        ConvertToMono16k(stereoSource, destination);

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

    public static void EncodeAac(string wavePath, string destination)
    {
        using var reader = new WaveFileReader(wavePath);
        MediaFoundationEncoder.EncodeToAac(reader, destination, 128_000);
    }
}
