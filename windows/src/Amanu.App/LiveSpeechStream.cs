using System.IO;
using System.Runtime.InteropServices;

namespace Amanu.App;

/// <summary>
/// One Nemotron model and decoder per side. v0.2.4's model holds mutable
/// compute buffers: sharing it between concurrently fed sessions corrupts text.
/// </summary>
public sealed unsafe class LiveSpeechStream : IDisposable
{
    private IntPtr model;
    private IntPtr session;
    private readonly string? language;
    private static readonly Lock initialization = new();
    private static bool initialized;
    private static bool resolverInstalled;

    public LiveSpeechStream(string runtimeDirectory, string modelPath, string? language, int threads)
    {
        this.language = language;
        lock (initialization)
        {
            if (!initialized)
            {
                if (!resolverInstalled)
                {
                    NativeLibrary.SetDllImportResolver(typeof(LiveSpeechStream).Assembly, (name, assembly, _) =>
                        name == Native.Library ? NativeLibrary.Load(Path.Combine(runtimeDirectory, "transcribe.dll"),
                            assembly, DllImportSearchPath.UseDllDirectoryForDependencies) : IntPtr.Zero);
                    resolverInstalled = true;
                }
                if (Marshal.PtrToStringUTF8(Native.transcribe_version()) != "0.2.4")
                    throw new InvalidDataException("The streaming runtime must be transcribe.cpp 0.2.4.");
                CheckSize(0, sizeof(ModelLoadParams));
                CheckSize(1, sizeof(SessionParams));
                CheckSize(2, sizeof(RunParams));
                CheckSize(3, sizeof(StreamParams));
                CheckSize(9, sizeof(StreamUpdate));
                CheckSize(10, sizeof(StreamText));
                CheckSize(12, 16); // transcribe_ext includes tail padding before family fields.
                Check(Native.transcribe_init_backends(runtimeDirectory));
                initialized = true;
            }
        }
        try
        {
            var load = new ModelLoadParams(); Native.transcribe_model_load_params_init(ref load);
            load.backend = 1; // CPU, explicitly: never fall back to shared Vulkan state.
            Check(Native.transcribe_model_load_file(modelPath, ref load, out model));
            var parameters = new SessionParams(); Native.transcribe_session_params_init(ref parameters);
            parameters.n_threads = Math.Max(1, threads);
            Check(Native.transcribe_session_init(model, ref parameters, out session));
            Begin();
        }
        catch { Dispose(); throw; }
    }

    public void Feed(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty) return;
        var update = new StreamUpdate { size = (ulong)sizeof(StreamUpdate) };
        fixed (float* pcm = samples) Check(Native.transcribe_stream_feed(session, pcm, samples.Length, ref update));
    }

    public string Text
    {
        get
        {
            var text = new StreamText(); Native.transcribe_stream_text_init(ref text);
            Check(Native.transcribe_stream_get_text(session, ref text));
            return (Marshal.PtrToStringUTF8(text.full_text, checked((int)text.full_text_bytes)) ?? "")
                .Replace("<unk>", "", StringComparison.Ordinal).Trim();
        }
    }

    public void FinalizeUtterance()
    {
        var update = new StreamUpdate { size = (ulong)sizeof(StreamUpdate) };
        Check(Native.transcribe_stream_finalize(session, ref update));
    }

    public void Begin()
    {
        Native.transcribe_stream_reset(session);
        var run = new RunParams(); Native.transcribe_run_params_init(ref run);
        run.language = language is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(language);
        try
        {
            // Nested transcribe_ext is 16 bytes, not the 12 bytes occupied by its fields.
            var extension = new ParakeetStreamExt { size = 24, kind = 0x54534B50u, att_context_right = 13 };
            var stream = new StreamParams(); Native.transcribe_stream_params_init(ref stream);
            stream.family = (IntPtr)(&extension);
            Check(Native.transcribe_stream_begin(session, ref run, ref stream));
        }
        finally { Marshal.FreeCoTaskMem(run.language); }
    }

    public void Dispose()
    {
        if (session != IntPtr.Zero) { Native.transcribe_session_free(session); session = IntPtr.Zero; }
        if (model != IntPtr.Zero) { Native.transcribe_model_free(model); model = IntPtr.Zero; }
    }

    private static void CheckSize(int id, int expected)
    {
        if (Native.transcribe_abi_struct_size(id) != (nuint)expected)
            throw new InvalidDataException($"Streaming runtime ABI mismatch (struct {id}).");
    }

    private static void Check(int status)
    {
        if (status != 0) throw new InvalidDataException("Streaming transcription: " + Marshal.PtrToStringUTF8(Native.transcribe_status_string(status)));
    }

    [StructLayout(LayoutKind.Sequential)] private struct ModelLoadParams { public ulong size; public int backend; public IntPtr device; }
    [StructLayout(LayoutKind.Sequential)] private struct SessionParams { public ulong size; public int n_threads, kv_type, n_ctx; }
    [StructLayout(LayoutKind.Sequential)] private struct RunParams
    {
        public ulong size; public int task, timestamps, pnc, itn, diarize;
        public IntPtr language, target_language; public byte keep_special_tags; public IntPtr family; public int spec_k_drafts;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StreamParams { public ulong size; public IntPtr family; public int commit_policy; public uint agreement_n; }
    [StructLayout(LayoutKind.Sequential)] private struct StreamUpdate
    {
        public ulong size; public byte result_changed, is_final; public int revision;
        public long input_received_ms, audio_committed_ms, buffered_ms; public byte committed_changed, tentative_changed;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StreamText
    {
        public ulong size; public IntPtr full_text; public ulong full_text_bytes; public IntPtr committed_text; public ulong committed_text_bytes;
        public IntPtr tentative_text; public ulong tentative_text_bytes, raw_tentative_start_bytes;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ParakeetStreamExt { public ulong size; public uint kind, pad; public int att_context_right, tail; }

    private static class Native
    {
        public const string Library = "amanu-live-transcribe";
        [DllImport(Library)] public static extern IntPtr transcribe_version();
        [DllImport(Library)] public static extern IntPtr transcribe_status_string(int status);
        [DllImport(Library)] public static extern nuint transcribe_abi_struct_size(int id);
        [DllImport(Library)] public static extern int transcribe_init_backends([MarshalAs(UnmanagedType.LPUTF8Str)] string directory);
        [DllImport(Library)] public static extern void transcribe_model_load_params_init(ref ModelLoadParams parameters);
        [DllImport(Library)] public static extern int transcribe_model_load_file([MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref ModelLoadParams parameters, out IntPtr model);
        [DllImport(Library)] public static extern void transcribe_model_free(IntPtr model);
        [DllImport(Library)] public static extern void transcribe_session_params_init(ref SessionParams parameters);
        [DllImport(Library)] public static extern int transcribe_session_init(IntPtr model, ref SessionParams parameters, out IntPtr session);
        [DllImport(Library)] public static extern void transcribe_session_free(IntPtr session);
        [DllImport(Library)] public static extern void transcribe_run_params_init(ref RunParams parameters);
        [DllImport(Library)] public static extern void transcribe_stream_params_init(ref StreamParams parameters);
        [DllImport(Library)] public static extern int transcribe_stream_begin(IntPtr session, ref RunParams run, ref StreamParams stream);
        [DllImport(Library)] public static extern int transcribe_stream_feed(IntPtr session, float* pcm, int count, ref StreamUpdate update);
        [DllImport(Library)] public static extern int transcribe_stream_finalize(IntPtr session, ref StreamUpdate update);
        [DllImport(Library)] public static extern void transcribe_stream_reset(IntPtr session);
        [DllImport(Library)] public static extern void transcribe_stream_text_init(ref StreamText text);
        [DllImport(Library)] public static extern int transcribe_stream_get_text(IntPtr session, ref StreamText text);
    }
}
