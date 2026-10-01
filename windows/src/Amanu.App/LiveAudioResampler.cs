using System.Buffers.Binary;
using System.IO;
using NAudio.Dsp;
using NAudio.Wave;

namespace Amanu.App;

/// <summary>Continuous, filtered conversion from WASAPI packets to 16 kHz mono.</summary>
public sealed class LiveAudioResampler
{
    private readonly WdlResampler resampler = new();
    private readonly WaveFormat format;
    private readonly bool floatingPoint;

    public LiveAudioResampler(WaveFormat format)
    {
        this.format = format;
        floatingPoint = format.Encoding == WaveFormatEncoding.IeeeFloat
            || format is WaveFormatExtensible extensible
            && extensible.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        if (floatingPoint ? format.BitsPerSample != 32 : format.BitsPerSample is not (8 or 16 or 24 or 32))
            throw new InvalidDataException("Unsupported live audio format.");
        resampler.SetMode(true, 2, false);
        resampler.SetFilterParms();
        resampler.SetFeedMode(true);
        resampler.SetRates(format.SampleRate, 16000);
    }

    public float[] Convert(ReadOnlySpan<byte> data, bool silent)
    {
        var frames = data.Length / format.BlockAlign;
        if (frames == 0) return [];
        var needed = resampler.ResamplePrepare(frames, 1, out var input);
        if (needed != frames) throw new InvalidDataException("The live resampler rejected a packet.");
        var bytes = format.BitsPerSample / 8;
        for (var frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            if (!silent)
                for (var channel = 0; channel < format.Channels; channel++)
                {
                    var sample = data.Slice(frame * format.BlockAlign + channel * bytes, bytes);
                    sum += floatingPoint ? BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(sample))
                        : bytes switch
                        {
                            1 => (sample[0] - 128) / 128f,
                            2 => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32768f,
                            3 => ((sample[0] | sample[1] << 8 | sample[2] << 16) << 8 >> 8) / 8388608f,
                            _ => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2147483648f,
                        };
                }
            input[frame] = float.IsFinite(sum) ? Math.Clamp(sum / format.Channels, -1, 1) : 0;
        }
        var output = new float[(int)Math.Ceiling(frames * 16000.0 / format.SampleRate) + 256];
        var produced = resampler.ResampleOut(output, frames, output.Length, 1);
        return output[..produced];
    }
}
