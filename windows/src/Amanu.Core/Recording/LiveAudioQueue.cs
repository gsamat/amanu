using System.Threading.Channels;

namespace Amanu.Core.Recording;

/// <summary>A nonblocking audio queue bounded by duration, rather than packet count.</summary>
public sealed class LiveAudioQueue<T>(int maximumSamples)
{
    private readonly Channel<(T Value, int Samples)> channel = Channel.CreateUnbounded<(T, int)>(
        new UnboundedChannelOptions { SingleReader = true, AllowSynchronousContinuations = false });
    private int samples;

    public bool TryWrite(T value, int count)
    {
        if (count <= 0) return true;
        if (Interlocked.Add(ref samples, count) > maximumSamples)
        {
            Interlocked.Add(ref samples, -count);
            return false;
        }
        if (channel.Writer.TryWrite((value, count))) return true;
        Interlocked.Add(ref samples, -count);
        return false;
    }

    public async IAsyncEnumerable<T> ReadAllAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (var packet in channel.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
        {
            Interlocked.Add(ref samples, -packet.Samples);
            yield return packet.Value;
        }
    }

    public void Complete() => channel.Writer.TryComplete();
}
