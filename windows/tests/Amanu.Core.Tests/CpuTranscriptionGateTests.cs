using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Core.Tests;

public sealed class CpuTranscriptionGateTests
{
    [Fact]
    public async Task Live_interrupts_batch_and_blocks_its_retry_until_live_finishes()
    {
        var gate = new CpuTranscriptionGate();
        var batch = await gate.EnterBatchAsync(CancellationToken.None);
        var liveTask = gate.EnterLiveAsync(CancellationToken.None);
        Assert.True(batch.Token.IsCancellationRequested);
        Assert.False(liveTask.IsCompleted);
        var retry = gate.EnterBatchAsync(CancellationToken.None);
        batch.Dispose();
        var live = await liveTask.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(retry.IsCompleted);
        live.Dispose();
        using var resumed = await retry.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(resumed.Token.IsCancellationRequested);
    }

    [Fact]
    public async Task Cancelling_waiting_live_request_does_not_block_future_batches()
    {
        var gate = new CpuTranscriptionGate();
        var batch = await gate.EnterBatchAsync(CancellationToken.None);
        using var cancellation = new CancellationTokenSource();
        var live = gate.EnterLiveAsync(cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => live);
        batch.Dispose();
        using var next = await gate.EnterBatchAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2));
    }
}
