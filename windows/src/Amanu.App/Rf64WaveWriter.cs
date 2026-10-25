using System.IO;
using System.Text;
using NAudio.Wave;

namespace Amanu.App;

/// <summary>Where a track's audio goes; the seam that lets <see cref="TrackWriter"/>'s failure handling be tested.</summary>
internal interface ITrackFile : IDisposable
{
    void Write(byte[] data, int offset, int count);

    /// <summary>Brings the header's lengths up to date, so a crash leaves a file every reader can open.</summary>
    void Flush();
}

/// <summary>
/// A WAV writer without RIFF's 4 GB ceiling. At 48 kHz stereo float a track
/// reaches 4 GB after about three hours, where NAudio's <see cref="WaveFileWriter"/>
/// throws. This writer starts an ordinary RIFF/WAVE file whose "JUNK" chunk
/// reserves room for a "ds64" chunk; when the file outgrows 32-bit sizes, the
/// header is rolled over in place to RF64 (EBU Tech 3306), which NAudio's
/// readers understand. Recordings that stay under 4 GB remain plain WAV files.
/// </summary>
internal sealed class Rf64WaveWriter : ITrackFile
{
    /// <summary>RIFF size, data size and sample count (64 bits each), then the table length (32 bits).</summary>
    internal const int Ds64Length = 28;
    private const long PlaceholderPosition = 12;

    private readonly FileStream stream;
    private readonly BinaryWriter writer;
    private readonly int blockAlign;
    private readonly long sizeLimit;
    private readonly long factSizePosition = -1;
    private readonly long dataSizePosition;
    private long dataLength;

    public Rf64WaveWriter(string path, WaveFormat format) : this(path, format, uint.MaxValue) { }

    /// <param name="sizeLimit">The largest size a 32-bit field describes; lowered only by tests.</param>
    internal Rf64WaveWriter(string path, WaveFormat format, long sizeLimit)
    {
        blockAlign = Math.Max(1, (int)format.BlockAlign);
        this.sizeLimit = sizeLimit;
        stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        writer = new BinaryWriter(stream, Encoding.ASCII, leaveOpen: true);
        writer.Write("RIFF"u8);
        writer.Write(0u);
        writer.Write("WAVE"u8);
        writer.Write("JUNK"u8);
        writer.Write(Ds64Length);
        writer.Write(new byte[Ds64Length]);
        writer.Write("fmt "u8);
        format.Serialize(writer);
        // As WaveFileWriter does: compressed and float formats carry a sample count.
        if (format.Encoding != WaveFormatEncoding.Pcm && format.BitsPerSample != 0)
        {
            writer.Write("fact"u8);
            writer.Write(4);
            factSizePosition = stream.Position;
            writer.Write(0u);
        }
        writer.Write("data"u8);
        dataSizePosition = stream.Position;
        writer.Write(0u);
        writer.Flush();
    }

    public long Length => dataLength;

    public void Write(byte[] data, int offset, int count)
    {
        stream.Write(data, offset, count);
        dataLength += count;
    }

    public void Flush()
    {
        var end = stream.Position;
        WriteSizes(writer, dataSizePosition, factSizePosition, dataLength, blockAlign, sizeLimit);
        stream.Position = end;
        stream.Flush();
    }

    public void Dispose()
    {
        try
        {
            if ((dataLength & 1) == 1) stream.WriteByte(0); // chunks are word-aligned
            WriteSizes(writer, dataSizePosition, factSizePosition, dataLength, blockAlign, sizeLimit);
        }
        finally
        {
            writer.Dispose();
            stream.Dispose();
        }
    }

    /// <summary>
    /// Writes every length in the header: plain RIFF while they fit 32 bits, RF64
    /// with a "ds64" chunk in the reserved place once they don't. Also used to
    /// repair the header of a track whose writer never finished.
    /// </summary>
    internal static void WriteSizes(BinaryWriter writer, long dataSizePosition, long factSizePosition, long dataLength,
        int blockAlign, long sizeLimit = uint.MaxValue)
    {
        var stream = writer.BaseStream;
        var riffSize = dataSizePosition + 4 + dataLength + (dataLength & 1) - 8;
        var frames = dataLength / Math.Max(1, blockAlign);
        var rf64 = riffSize > sizeLimit || dataLength > sizeLimit;
        stream.Position = 0;
        writer.Write(rf64 ? "RF64"u8 : "RIFF"u8);
        writer.Write(rf64 ? uint.MaxValue : (uint)riffSize);
        stream.Position = PlaceholderPosition;
        if (rf64)
        {
            writer.Write("ds64"u8);
            writer.Write(Ds64Length);
            writer.Write(riffSize);
            writer.Write(dataLength);
            writer.Write(frames);
            writer.Write(0u);
        }
        else
        {
            writer.Write("JUNK"u8); // the reserved room again, every reader skips it
        }
        if (factSizePosition >= 0)
        {
            stream.Position = factSizePosition;
            writer.Write(rf64 ? uint.MaxValue : (uint)frames);
        }
        stream.Position = dataSizePosition;
        writer.Write(rf64 ? uint.MaxValue : (uint)dataLength);
        writer.Flush();
    }
}
