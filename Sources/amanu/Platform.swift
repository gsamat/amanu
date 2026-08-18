/// What this slice of the binary can do.
///
/// amanu ships as one universal binary, so the same release runs on Apple
/// Silicon and on the Intel Macs still taking macOS 15. The local speech
/// models are the one thing that does not cross over: they are Core ML
/// packages compiled for the Neural Engine, and FluidAudio refuses them
/// outright on x86_64 rather than falling back to the CPU — which is the
/// honest answer, because the CPU fallback would be slower than the meeting.
///
/// Everything else — recording, the process tap, summaries, the cloud engine —
/// is architecture-agnostic. So an Intel Mac gets the whole recorder and
/// transcribes through AssemblyAI, and the code that would otherwise reach for
/// a local model asks here first.
enum Platform {
    /// Whether local speech models (parakeet for the transcript, Nemotron for
    /// the live one) can run at all. Compile-time, per slice: the arm64 half
    /// of the universal binary says yes, the x86_64 half says no.
    static let supportsLocalModels: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}
