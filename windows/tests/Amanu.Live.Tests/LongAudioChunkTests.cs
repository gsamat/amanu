using System.IO;
using Amanu.App;
using NAudio.Wave;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class LongAudioChunkTests
{
    [Fact]
    public void Context_chunks_cover_the_track_once_and_keep_audio_across_the_cut()
    {
        var root = Path.Combine(Path.GetTempPath(), "amanu-context-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var wave = Path.Combine(root, "input.wav");
            using (var writer = new WaveFileWriter(wave, new WaveFormat(16000, 16, 1)))
            {
                var samples = new short[125 * 16000];
                // Two sides of the first boundary must survive in both context windows.
                samples[60 * 16000 - 1] = 1234;
                samples[60 * 16000] = 2345;
                var bytes = new byte[samples.Length * 2];
                Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
                writer.Write(bytes, 0, bytes.Length);
            }
            var chunks = AudioPreprocessor.SplitWithContext(wave, root, 60, 1);
            Assert.Equal(3, chunks.Count);
            Assert.Equal(new long[] { 0, 60000, 120000 }, chunks.Select(chunk => chunk.StartMs));
            Assert.Equal(new long[] { 60000, 120000, 125000 }, chunks.Select(chunk => chunk.EndMs));
            Assert.Equal(new long[] { 0, 59000, 119000 }, chunks.Select(chunk => chunk.OffsetMs));
            foreach (var chunk in chunks)
            {
                using var reader = new WaveFileReader(chunk.Path);
                Assert.InRange(reader.TotalTime.TotalSeconds, 1, 62);
            }
            foreach (var chunk in chunks.Take(2))
            {
                using var reader = new WaveFileReader(chunk.Path);
                reader.Position = (60000 - chunk.OffsetMs) * 32 - 2;
                var bytes = new byte[4];
                Assert.Equal(4, reader.Read(bytes, 0, 4));
                Assert.Equal(1234, BitConverter.ToInt16(bytes, 0));
                Assert.Equal(2345, BitConverter.ToInt16(bytes, 2));
            }
        }
        finally { Directory.Delete(root, true); }
    }
}
