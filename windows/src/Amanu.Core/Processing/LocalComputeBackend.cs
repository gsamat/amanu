namespace Amanu.Core.Processing;

/// <summary>
/// Which <c>--backend</c> a final-transcript pass asks transcribe-cli for. With
/// <c>transcription.local_device</c> at <c>auto</c> the CLI takes a GPU when the
/// runtime registered one through Vulkan and the processor otherwise, so a
/// machine without a usable GPU behaves exactly as before. Once the processor
/// has finished a pass the GPU could not, the GPU is not asked again until Amanu
/// restarts: a driver that lost the device, or a card without room for the
/// model, fails the same way on the next file, and every attempt costs a load.
/// </summary>
public sealed class LocalComputeBackend
{
    public const string Processor = "cpu";
    public const string Automatic = "auto";

    private volatile bool gpuFailed;

    public bool GpuHasFailed => gpuFailed;

    public string For(string? localDevice) =>
        localDevice == Processor || gpuFailed ? Processor : Automatic;

    public void ProcessorSucceededWhereGpuFailed() => gpuFailed = true;
}
