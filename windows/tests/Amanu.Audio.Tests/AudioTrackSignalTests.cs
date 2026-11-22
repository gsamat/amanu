using Amanu.App;
using NAudio.Wave;
using Xunit;

namespace Amanu.Audio.Tests;

public sealed class AudioTrackSignalTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Captured_track_is_skipped_only_when_every_channel_is_silent(bool hasSignal)
    {
        using var files = new SessionFiles();
        var path = files.Session.SystemTrack;
        using (var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(48_000, 2)))
        {
            var stereo = new float[96_000];
            if (hasSignal) stereo[^1] = .00001f;
            writer.WriteSamples(stereo, 0, stereo.Length);
        }

        Assert.True(AudioPreprocessor.HasSamples(path));
        Assert.Equal(hasSignal, AudioPreprocessor.HasSignal(path, default));
        Assert.True(File.Exists(path));
    }
}
