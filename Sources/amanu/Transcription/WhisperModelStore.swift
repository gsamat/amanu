import Foundation

/// The one Whisper model Amanu supports as a first production default.
/// Downloading, verifying and sharing it is `VerifiedModelStore`'s job.
struct WhisperModelStore: Sendable {
    typealias Manifest = VerifiedModelStore.Manifest
    typealias Progress = VerifiedModelStore.Progress
    typealias Error = VerifiedModelStore.Error
    typealias ProgressHandler = VerifiedModelStore.ProgressHandler
    typealias Downloader = VerifiedModelStore.Downloader

    /// Hugging Face's immutable revision which introduced this exact model.
    /// 574,041,195 bytes is 547.4 MiB, presented in the setup UI as about
    /// 550 MB while the progress bar uses the response's real byte counts.
    static let defaultManifest = Manifest(
        id: "large-v3-turbo-q5_0",
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
        downloadURL: URL(string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin?download=true"
        )!,
        expectedBytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")

    /// The optional Silero VAD model published by whisper.cpp's maintainers.
    /// It uses the same verified, atomic and shared download as the ASR model.
    static let vadManifest = Manifest(
        id: "silero-v6.2.0",
        fileName: "ggml-silero-v6.2.0.bin",
        revision: "9ffd54a1e1ee413ddf265af9913beaf518d1639b",
        downloadURL: URL(string:
            "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin?download=true"
        )!,
        expectedBytes: 885_098,
        sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")

    static let advertisedDownloadBytes: Int64 = 550 * 1_048_576

    private let store: VerifiedModelStore

    init(
        directory: URL = Home.current.url
            .appendingPathComponent("Library/Application Support/amanu/models/whisper", isDirectory: true),
        manifest: Manifest = WhisperModelStore.defaultManifest,
        downloader: @escaping Downloader = { try await ModelDownloader.download(source: $0, partial: $1, progress: $2) }
    ) {
        store = VerifiedModelStore(directory: directory, manifest: manifest, downloader: downloader)
    }

    var directory: URL { store.directory }
    var manifest: Manifest { store.manifest }
    var modelURL: URL { store.modelURL }
    var partialURL: URL { store.partialURL }
    var bytesOnDisk: Int { store.bytesOnDisk }

    func download(progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        try await store.download(progress: progress)
    }

    func delete() throws { try store.delete() }
}
