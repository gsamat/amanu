using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Core.Tests;

public sealed class LocalComputeBackendTests
{
    [Fact]
    public void Auto_lets_the_runtime_pick_a_gpu()
    {
        Assert.Equal("auto", new LocalComputeBackend().For("auto"));
    }

    [Fact]
    public void Cpu_keeps_every_pass_on_the_processor()
    {
        Assert.Equal("cpu", new LocalComputeBackend().For("cpu"));
    }

    [Fact]
    public void A_gpu_that_failed_once_is_not_asked_again()
    {
        var backend = new LocalComputeBackend();
        backend.ProcessorSucceededWhereGpuFailed();

        Assert.True(backend.GpuHasFailed);
        Assert.Equal("cpu", backend.For("auto"));
    }

    [Fact]
    public void The_default_setting_is_auto_and_cpu_is_the_only_alternative()
    {
        Assert.Equal("auto", new TranscriptionSettings().LocalDevice);
        Assert.Equal(new[] { "auto", "cpu" }, TranscriptionSettings.LocalDevices);
    }
}
