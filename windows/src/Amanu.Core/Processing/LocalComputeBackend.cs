namespace Amanu.Core.Processing;

/// <summary>
/// Whether a final-transcript pass goes to the GPU runtime. With
/// <c>transcription.local_device</c> at <c>auto</c> it does whenever the package
/// carries one; that CLI then takes a GPU if Vulkan offers one and the
/// processor otherwise, so a machine without a usable GPU transcribes as before.
/// Once the processor runtime has finished a pass the GPU runtime could not,
/// the GPU is not asked again until Amanu restarts: a driver that lost the
/// device, or a card without room for the model, fails the same way on the next
/// file, and every attempt costs a model load.
/// </summary>
public sealed class LocalComputeBackend
{
    public const string Processor = "cpu";
    public const string Automatic = "auto";

    private volatile bool gpuFailed;

    public bool GpuHasFailed => gpuFailed;

    public bool UseGpu(string? localDevice, bool gpuRuntimePresent) =>
        gpuRuntimePresent && localDevice != Processor && !gpuFailed;

    public void ProcessorSucceededWhereGpuFailed() => gpuFailed = true;
}
