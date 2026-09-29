using Amanu.Core.Processing;

namespace Amanu.Core.Tests;

public sealed class ProcessingFailureTests
{
    [Theory]
    [InlineData(null, FailureKind.Environmental, true)]
    [InlineData(401, FailureKind.Environmental, false)]
    [InlineData(403, FailureKind.Environmental, false)]
    [InlineData(429, FailureKind.Transient, false)]
    [InlineData(503, FailureKind.Transient, false)]
    [InlineData(400, FailureKind.Recording, false)]
    public void Only_the_service_refusing_this_audio_costs_an_attempt(int? status, FailureKind kind, bool unreachable)
    {
        var failure = ProcessingFailure.FromHttp("AssemblyAI", status, "detail");
        Assert.Equal(kind, failure.Kind);
        Assert.Equal(unreachable, failure.Unreachable);
    }
}
