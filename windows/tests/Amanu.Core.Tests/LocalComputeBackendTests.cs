using Amanu.Core.Configuration;
using Amanu.Core.Processing;
using Xunit;

namespace Amanu.Core.Tests;

public sealed class LocalComputeBackendTests
{
    [Fact]
    public void Auto_uses_the_gpu_runtime_when_the_package_has_one()
    {
        Assert.True(new LocalComputeBackend().UseGpu("auto", gpuRuntimePresent: true));
    }

    [Fact]
    public void A_processor_only_package_stays_on_the_processor()
    {
        Assert.False(new LocalComputeBackend().UseGpu("auto", gpuRuntimePresent: false));
    }

    [Fact]
    public void Cpu_keeps_every_pass_on_the_processor()
    {
        Assert.False(new LocalComputeBackend().UseGpu("cpu", gpuRuntimePresent: true));
    }

    [Fact]
    public void A_gpu_that_failed_once_is_not_asked_again()
    {
        var backend = new LocalComputeBackend();
        backend.ProcessorSucceededWhereGpuFailed();

        Assert.True(backend.GpuHasFailed);
        Assert.False(backend.UseGpu("auto", gpuRuntimePresent: true));
    }

    [Fact]
    public void The_default_setting_is_auto_and_cpu_is_the_only_alternative()
    {
        Assert.Equal("auto", new TranscriptionSettings().LocalDevice);
        Assert.Equal(new[] { "auto", "cpu" }, TranscriptionSettings.LocalDevices);
    }
}
