import FluidAudio
import Foundation

/// The local speech models as files on a disk: which of them are on this Mac,
/// what they weigh, and how to get the space back.
///
/// The windows quote sizes from here rather than from a constant. The numbers
/// in the form's prose — "about 460 MB" — are what a download is going to
/// cost before it happens, and they have to be written down somewhere because
/// nothing has been fetched yet. Once the files are there the only honest
/// figure is the one measured off the disk, and the two differ by more than
/// rounding: the live model's cache keeps every language variant that has
/// ever been fetched, so it grows without anything in the window changing.
///
/// Deleting is not the same as switching off, which is the whole reason
/// `updatesAfterDeleting` exists. A model deleted while the switch that wants
/// it is still on comes back on the next meeting, quietly, over the same
/// connection the person was trying to spare — and the space they thought
/// they had freed is gone again without anybody being told.
struct ModelStorage {
    /// One model, as a person is shown it.
    struct Model: Equatable {
        /// Which switch in the setup form asks for this model. The version is
        /// in the name and the path; nothing outside this file has to know
        /// that parakeet has versions at all.
        enum Kind: Equatable {
            case parakeet
            case live
        }

        let kind: Kind
        /// A name, so not translated — these are the words the release notes,
        /// the config file and the setup form all use.
        let name: String
        let directory: URL
        /// What the directory holds, in bytes. Zero when it isn't there,
        /// which is also what `isDownloaded` reads.
        let bytes: Int

        var isDownloaded: Bool { bytes > 0 }
    }

    private let live: LiveTranscriptionModelStore
    private let parakeetCache: @Sendable (AsrModelVersion) -> URL

    init(
        live: LiveTranscriptionModelStore = LiveTranscriptionModelStore(),
        parakeetCache: @escaping @Sendable (AsrModelVersion) -> URL = {
            AsrModels.defaultCacheDirectory(for: $0)
        }
    ) {
        self.live = live
        self.parakeetCache = parakeetCache
    }

    /// Every model worth showing, in the order the setup form asks for them.
    ///
    /// The configured parakeet version is listed whether or not it is here —
    /// its row is where a person reads that it isn't. Another version is
    /// listed only when its files exist: a version nobody chose and nobody
    /// downloaded is not news, but half a gigabyte left behind by a version
    /// somebody has since changed away from is exactly what this list is for.
    func all(configured: AsrModelVersion = ParakeetEngine.configuredVersion()) -> [Model] {
        var models = [parakeet(version: configured)]
        for version in [AsrModelVersion.v3, .v2] where version != configured {
            let other = parakeet(version: version)
            if other.isDownloaded { models.append(other) }
        }
        models.append(liveModel())
        return models
    }

    func parakeet(version: AsrModelVersion) -> Model {
        let directory = parakeetCache(version)
        return Model(
            kind: .parakeet,
            name: "parakeet \(version == .v2 ? "v2" : "v3")",
            directory: directory,
            bytes: Self.bytes(of: directory))
    }

    func liveModel() -> Model {
        Model(
            kind: .live,
            name: "NVIDIA nemotron",
            directory: live.modelDirectory,
            bytes: Self.bytes(of: live.modelDirectory))
    }

    /// What everything listed comes to. The number a person came to the
    /// window for, and the one they can compare against what the disk says.
    func total(_ models: [Model]) -> Int {
        models.reduce(0) { $0 + $1.bytes }
    }

    /// Put the directory back the way it was before the download. Removing
    /// the whole directory rather than the files we know about: FluidAudio
    /// writes more into it than it reads back, and a half-emptied cache is
    /// the state its downloader is worst at recovering from.
    func delete(_ model: Model) throws {
        guard FileManager.default.fileExists(atPath: model.directory.path) else { return }
        try FileManager.default.removeItem(at: model.directory)
    }

    /// What to write when a model is deleted: the switch that asked for it
    /// has to come down with it. Returned as config paths rather than done
    /// here so the whole matrix can be checked without a disk.
    ///
    /// Deleting parakeet on a Mac with no cloud engine leaves nothing to
    /// transcribe with, and `TranscriptionChoice` says so by switching
    /// transcription off outright. That is the truth about what was just
    /// done, and the window says it out loud before doing it.
    static func updatesAfterDeleting(
        _ kind: Model.Kind,
        choice: TranscriptionChoice,
        liveEnabled: Bool
    ) -> [(path: [String], value: Any?)] {
        switch kind {
        case .parakeet:
            guard choice.local else { return [] }
            return TranscriptionChoice(cloud: choice.cloud, local: false, provider: choice.provider)
                .updates
        case .live:
            return liveEnabled ? [(["live_transcription", "enabled"], nil)] : []
        }
    }

    /// A size as a person reads it: megabytes until they stop being readable,
    /// and the decimal separator the window's language uses rather than the
    /// one `String(format:)` picks.
    static func describe(bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_048_576
        guard megabytes >= 1024 else {
            return localised("\(Int(megabytes.rounded())) MB", "\(Int(megabytes.rounded())) МБ")
        }
        let gigabytes = String(format: "%.1f", megabytes / 1024)
        return localised(
            "\(gigabytes) GB",
            gigabytes.replacingOccurrences(of: ".", with: ",") + " ГБ")
    }

    /// What a directory holds, in bytes. The same walk the download progress
    /// bar does once a second, so nothing here is a cost the window doesn't
    /// already pay.
    static func bytes(of directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
