namespace Amanu.Core.Processing;

/// <summary>Live recognition preempts a retryable batch pass and owns the CPU until its models are freed.</summary>
public sealed class CpuTranscriptionGate
{
    private readonly object sync = new();
    private readonly SemaphoreSlim slot = new(1);
    private TaskCompletionSource idle = Completed();
    private CancellationTokenSource? batch;
    private int liveRequests;

    private static TaskCompletionSource Completed()
    {
        var source = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        source.SetResult();
        return source;
    }

    public async Task<IDisposable> EnterLiveAsync(CancellationToken token)
    {
        CancellationTokenSource? interrupt;
        lock (sync)
        {
            if (liveRequests++ == 0) idle = new(TaskCreationOptions.RunContinuationsAsynchronously);
            interrupt = batch;
        }
        try { interrupt?.Cancel(); } catch (ObjectDisposedException) { }
        try { await slot.WaitAsync(token).ConfigureAwait(false); }
        catch { ReleaseLiveRequest(); throw; }
        return new Lease(() => { slot.Release(); ReleaseLiveRequest(); });
    }

    private void ReleaseLiveRequest()
    {
        lock (sync) if (--liveRequests == 0) idle.TrySetResult();
    }

    public async Task<BatchLease> EnterBatchAsync(CancellationToken token)
    {
        while (true)
        {
            Task wait;
            lock (sync) wait = idle.Task;
            await wait.WaitAsync(token).ConfigureAwait(false);
            await slot.WaitAsync(token).ConfigureAwait(false);
            lock (sync)
            {
                if (liveRequests == 0)
                {
                    var source = CancellationTokenSource.CreateLinkedTokenSource(token);
                    batch = source;
                    return new BatchLease(source.Token, () =>
                    {
                        lock (sync) batch = null;
                        source.Dispose();
                        slot.Release();
                    });
                }
            }
            slot.Release();
        }
    }

    public sealed class BatchLease(CancellationToken token, Action release) : Lease(release)
    {
        public CancellationToken Token { get; } = token;
    }

    public class Lease(Action release) : IDisposable
    {
        private Action? action = release;
        public void Dispose() => Interlocked.Exchange(ref action, null)?.Invoke();
    }
}
