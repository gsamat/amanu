using System.IO;
using Amanu.App;
using NAudio.Wave;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class TrackWriterTests : IDisposable
{
    private static readonly WaveFormat Float48kStereo = WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2);
    private readonly string directory = Path.Combine(Path.GetTempPath(), "amanu-track-" + Guid.NewGuid().ToString("N"));

    public TrackWriterTests() => Directory.CreateDirectory(directory);

    public void Dispose() => Directory.Delete(directory, recursive: true);

    [Fact]
    public void A_short_track_stays_a_plain_wav_file()
    {
        var path = Path.Combine(directory, "mic.wav");
        var audio = Pattern(48_000 * 8);
        using (var writer = new Rf64WaveWriter(path, Float48kStereo)) writer.Write(audio, 0, audio.Length);

        Assert.Equal("RIFF", Header(path));
        AssertReadsBack(path, audio);
    }

    [Fact]
    public void A_track_past_the_32_bit_limit_rolls_over_to_rf64_and_reads_back_whole()
    {
        // The limit stands in for 4 GB; writing gigabytes would make the test useless.
        var path = Path.Combine(directory, "mic.wav");
        var audio = Pattern(10_000);
        using (var writer = new Rf64WaveWriter(path, Float48kStereo, sizeLimit: 4_096))
        {
            writer.Write(audio, 0, 3_000);
            writer.Flush();
            Assert.Equal("RIFF", Header(path)); // still small enough
            writer.Write(audio, 3_000, audio.Length - 3_000);
        }

        Assert.Equal("RF64", Header(path));
        AssertReadsBack(path, audio);
    }

    [Fact]
    public void A_track_cut_off_after_its_last_header_update_is_repaired_to_its_full_length()
    {
        var path = Path.Combine(directory, "mic.wav");
        var audio = Pattern(8_000);
        using (var writer = new Rf64WaveWriter(path, Float48kStereo)) writer.Write(audio, 0, 6_000);
        // Samples written after the last header update, then the power goes.
        using (var raw = new FileStream(path, FileMode.Append)) raw.Write(audio, 6_000, 2_000);

        AudioPreprocessor.RepairHeader(path);

        AssertReadsBack(path, audio);
    }

    [Fact]
    public void Writer_faults_neither_stop_the_queue_nor_leave_the_file_open()
    {
        var file = new FailingTrackFile();
        var writer = new TrackWriter(file, Float48kStereo, origin100ns: 1_000_000);
        const int packets = 200;
        var buffer = Pattern(480 * Float48kStereo.BlockAlign); // 10 ms
        for (var i = 0; i < packets; i++) writer.Write(buffer, false, 1_000_000 + i * 100_000L, false);

        writer.Dispose(); // must not throw

        Assert.True(file.Disposed);
        Assert.True(file.Attempts >= packets, $"only {file.Attempts} of {packets} packets reached the writer");
    }

    [Fact]
    public void A_finished_track_is_closed_and_readable()
    {
        var path = Path.Combine(directory, "system.wav");
        var writer = new TrackWriter(path, Float48kStereo, origin100ns: 1_000_000);
        var buffer = Pattern(480 * Float48kStereo.BlockAlign);
        for (var i = 0; i < 100; i++) writer.Write(buffer, false, 1_000_000 + i * 100_000L, false);
        writer.Dispose();

        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { } // no handle left open
        using var reader = new WaveFileReader(path);
        Assert.Equal(100 * buffer.Length, reader.Length);
    }

    private static byte[] Pattern(int length)
    {
        var bytes = new byte[length];
        for (var i = 0; i < length; i++) bytes[i] = (byte)(i * 31 + 7);
        return bytes;
    }

    private static string Header(string path)
    {
        using var reader = new BinaryReader(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite));
        return new string(reader.ReadChars(4));
    }

    private static void AssertReadsBack(string path, byte[] expected)
    {
        using var reader = new WaveFileReader(path);
        Assert.Equal(Float48kStereo.SampleRate, reader.WaveFormat.SampleRate);
        Assert.Equal(Float48kStereo.Channels, reader.WaveFormat.Channels);
        Assert.Equal(expected.Length, reader.Length);
        var actual = new byte[expected.Length];
        Assert.Equal(expected.Length, reader.Read(actual, 0, actual.Length));
        Assert.Equal(expected, actual);
    }

    private sealed class FailingTrackFile : ITrackFile
    {
        public int Attempts;
        public bool Disposed;

        public void Write(byte[] data, int offset, int count)
        {
            Interlocked.Increment(ref Attempts);
            throw new ArgumentException("WAV file too large", nameof(count)); // what NAudio's WaveFileWriter throws at 4 GB
        }

        public void Flush() { }

        public void Dispose() => Disposed = true;
    }
}
