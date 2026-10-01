using Amanu.App;
using Amanu.Core.Recording;
using NAudio.Wave;
using Xunit;

namespace Amanu.Live.Tests;

public sealed class LiveAudioTests
{
    [Fact]
    public void Idle_decoder_skips_silence_but_keeps_a_frame_containing_quiet_speech()
    {
        Assert.False(LiveTranscriptionCoordinator.HasAudibleAudio(new float[17920]));
        Assert.True(LiveTranscriptionCoordinator.HasAudibleAudio(Enumerable.Repeat(0.0002f, 17920).ToArray()));
        var frame = new float[17920];
        for (var index = 8000; index < 9000; index++) frame[index] = 0.0005f;
        Assert.True(LiveTranscriptionCoordinator.HasAudibleAudio(frame));
    }
    [Fact]
    public async Task Queue_bounds_audio_duration_and_returns_capacity_after_consumption()
    {
        var queue = new LiveAudioQueue<string>(16000);
        Assert.True(queue.TryWrite("first", 12000));
        Assert.False(queue.TryWrite("too much", 5000));
        Assert.True(queue.TryWrite("last", 4000));
        await using var reader = queue.ReadAllAsync(CancellationToken.None).GetAsyncEnumerator();
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal("first", reader.Current);
        Assert.True(queue.TryWrite("after read", 12000));
        queue.Complete();
        Assert.False(queue.TryWrite("after close", 1));
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal("last", reader.Current);
        Assert.True(await reader.MoveNextAsync());
        Assert.Equal("after read", reader.Current);
        Assert.False(await reader.MoveNextAsync());
    }

    [Fact]
    public void Resampling_small_packets_preserves_continuity_and_audio_duration()
    {
        var format = WaveFormat.CreateIeeeFloatWaveFormat(48000, 2);
        var samples = new float[48000 * 2];
        for (var frame = 0; frame < 48000; frame++)
            samples[frame * 2] = samples[frame * 2 + 1] = (float)(0.5 * Math.Sin(2 * Math.PI * 440 * frame / 48000));
        var bytes = new byte[samples.Length * 4];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        var whole = new LiveAudioResampler(format).Convert(bytes, false);
        var converter = new LiveAudioResampler(format);
        var packets = new List<float>();
        for (var offset = 0; offset < bytes.Length; offset += 480 * 8)
            packets.AddRange(converter.Convert(bytes.AsSpan(offset, 480 * 8), false));
        Assert.InRange(packets.Count, 15990, 16010);
        Assert.Equal(whole.Length, packets.Count);
        for (var index = 0; index < whole.Length; index++) Assert.InRange(Math.Abs(whole[index] - packets[index]), 0, 0.0001);
        Assert.InRange(packets.Select(sample => sample * sample).Average(), 0.12, 0.13);
    }

    [Theory]
    [InlineData(16)]
    [InlineData(24)]
    [InlineData(32)]
    public void Silent_capture_packets_ignore_their_payload(int bits)
    {
        var format = new WaveFormat(16000, bits, 1);
        var bytes = Enumerable.Repeat((byte)0x7f, format.AverageBytesPerSecond).ToArray();
        var samples = new LiveAudioResampler(format).Convert(bytes, true);
        Assert.InRange(samples.Length, 15990, 16010);
        Assert.All(samples, sample => Assert.Equal(0, sample));
    }
}
