import FluidAudio
import Foundation

/// Owns the optional Nemotron streaming-model cache. The model is never
/// downloaded as a side effect of starting a recording: setup/settings must
/// request it explicitly, keeping the feature genuinely opt-in.
struct LiveTranscriptionModelStore: Sendable {
    static let chunkMilliseconds = 1120

    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func variantDirectory(language: String) -> URL {
        root
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent(
                StreamingNemotronMultilingualAsrManager.languageDirectory(for: language),
                isDirectory: true
            )
            .appendingPathComponent("\(Self.chunkMilliseconds)ms", isDirectory: true)
    }

    /// A complete variant needs metadata/tokenizer, the encoder and one valid
    /// decode path. Checking more than FluidAudio's metadata marker lets the UI
    /// distinguish an interrupted download from a model that is ready to load.
    func isReady(language: String) -> Bool {
        let dir = variantDirectory(language: language)
        let exists: (String) -> Bool = { name in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        guard exists("metadata.json"), exists("tokenizer.json"),
              exists("encoder.mlmodelc") || exists("encoder.mlpackage")
        else { return false }

        let fused = [
            "decoder_joint_argmax", "decoder_joint_noencproj", "decoder_joint",
        ].contains { exists("\($0).mlmodelc") || exists("\($0).mlpackage") }
        let split = (exists("decoder.mlmodelc") || exists("decoder.mlpackage"))
            && (exists("joint.mlmodelc") || exists("joint.mlpackage"))
        return fused || split
    }

    @discardableResult
    func download(
        language: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let variant = variantDirectory(language: language)
        if !isReady(language: language) {
            // FluidAudio uses metadata.json as its cache-complete marker. If
            // setup was interrupted after that file arrived but before a
            // model asset did, remove only the marker so its downloader makes
            // a repair pass and reuses every intact file already present.
            try? FileManager.default.removeItem(
                at: variant.appendingPathComponent("metadata.json"))
        }
        return try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: language,
            chunkMs: Self.chunkMilliseconds,
            to: root
        ) { update in
            progress?(update.fractionCompleted)
        }
    }
}
