import FluidAudio
import Foundation
import Testing

@testable import amanu

/// What the models on the disk weigh, which of them are worth listing, and
/// what has to be switched off when one is deleted.
///
/// Every one of these can be answered without a model: the sizes are read off
/// directories this suite builds, and the config half is a pure function, so
/// the matrix — cloud on, cloud off, switch already off — is checked here
/// rather than by deleting half a gigabyte and putting it back.
struct ModelStorageTests {
    /// A directory with `count` files of a kilobyte each, and nothing else.
    private static func directory(_ root: URL, _ name: String, files: Int) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<files {
            try Data(repeating: 0, count: 1024)
                .write(to: dir.appendingPathComponent("part-\(index).bin"))
        }
        return dir
    }

    private static func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A storage whose two caches are inside `root`, so nothing here can see
    /// — or delete — a model the machine running the tests actually has.
    private static func storage(in root: URL) -> ModelStorage {
        ModelStorage(
            live: LiveTranscriptionModelStore(root: root.appendingPathComponent("live")),
            parakeetCache: { version in
                root.appendingPathComponent(version == .v2 ? "parakeet-v2" : "parakeet-v3")
            })
    }

    @Test("A directory's size is what its files add up to, and an absent one is zero")
    func measuring() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = try Self.directory(root, "cache", files: 3)
        #expect(ModelStorage.bytes(of: dir) == 3 * 1024)
        #expect(ModelStorage.bytes(of: root.appendingPathComponent("nothing here")) == 0)
    }

    @Test("The configured version is always listed; another one only when it's there")
    func listing() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Self.storage(in: root)

        // Nothing downloaded at all: the configured version is still listed,
        // because its row is where a person reads that it isn't here.
        let empty = storage.all(configured: .v3)
        #expect(empty.map(\.name) == ["parakeet v3", "NVIDIA nemotron"])
        #expect(empty.allSatisfy { !$0.isDownloaded })
        #expect(storage.total(empty) == 0)

        // Half a gigabyte left behind by a version nobody uses any more is
        // exactly what the list is for.
        _ = try Self.directory(root, "parakeet-v2", files: 2)
        _ = try Self.directory(root, "parakeet-v3", files: 4)
        let both = storage.all(configured: .v3)
        #expect(both.map(\.name) == ["parakeet v3", "parakeet v2", "NVIDIA nemotron"])
        #expect(storage.total(both) == 6 * 1024)
    }

    @Test("The live model is measured and deleted whole, variants and all")
    func liveModelIsOneThing() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptionModelStore(root: root.appendingPathComponent("live"))
        let storage = ModelStorage(live: store, parakeetCache: { _ in root })

        let variant = store.variantDirectory(language: "multilingual")
        try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 2048).write(to: variant.appendingPathComponent("encoder"))

        let model = storage.liveModel()
        #expect(model.bytes == 2048)
        #expect(model.directory == store.modelDirectory)

        try storage.delete(model)
        #expect(!FileManager.default.fileExists(atPath: store.modelDirectory.path))
        #expect(!store.isReady(language: "multilingual"))
        // Deleting what is already gone is what a second click on a stale
        // window is, and it is not an error.
        try storage.delete(model)
    }

    @Test("Deleting parakeet brings the switch that wanted it down too")
    func parakeetSwitchesOff() {
        let cloudAndLocal = TranscriptionChoice(cloud: true, local: true, provider: "assemblyai")
        let written = ModelStorage.updatesAfterDeleting(
            .parakeet, choice: cloudAndLocal, liveEnabled: false)
        #expect(written.map(\.path) == [
            ["transcription", "enabled"], ["transcription", "engine"], ["transcription", "cloud"],
        ])
        // The cloud stays, so the engine stops being "whichever answers" and
        // becomes the one that is left.
        #expect(written[1].value as? String == "assemblyai")

        // Nothing else can transcribe, so transcription goes off outright —
        // the honest consequence, and what the alert says out loud.
        let localOnly = TranscriptionChoice(cloud: false, local: true, provider: "assemblyai")
        let off = ModelStorage.updatesAfterDeleting(
            .parakeet, choice: localOnly, liveEnabled: false)
        #expect(off.count == 1)
        #expect(off[0].path == ["transcription", "enabled"])
        #expect(off[0].value as? Bool == false)

        // The switch is already off: deleting the files it left behind
        // changes no setting at all.
        let cloudOnly = TranscriptionChoice(cloud: true, local: false, provider: "openai")
        #expect(ModelStorage.updatesAfterDeleting(
            .parakeet, choice: cloudOnly, liveEnabled: false).isEmpty)
    }

    @Test("Deleting the live model switches the live transcript off, once")
    func liveSwitchesOff() {
        let choice = TranscriptionChoice(cloud: true, local: true, provider: "assemblyai")
        let written = ModelStorage.updatesAfterDeleting(
            .live, choice: choice, liveEnabled: true)
        #expect(written.count == 1)
        #expect(written[0].path == ["live_transcription", "enabled"])
        // Cleared rather than written false: a setting back at its default
        // belongs out of the file entirely.
        #expect(written[0].value == nil)

        #expect(ModelStorage.updatesAfterDeleting(
            .live, choice: choice, liveEnabled: false).isEmpty)
        // Deleting parakeet is not a reason to turn the live transcript off.
        #expect(ModelStorage.updatesAfterDeleting(
            .parakeet,
            choice: TranscriptionChoice(cloud: true, local: false, provider: "assemblyai"),
            liveEnabled: true
        ).isEmpty)
    }

    /// A test process is in English and nothing here changes that: the
    /// language a size is written in is `InterfaceLanguageTests`' question,
    /// and the suite that flips the language for the whole program is the
    /// only one that should.
    @Test("A size is rounded to something a person reads")
    func describing() {
        #expect(ModelStorage.describe(bytes: 461 * 1_048_576) == "461 MB")
        #expect(ModelStorage.describe(bytes: 0) == "0 MB")
        // Past a thousand megabytes the number stops being one anybody reads.
        #expect(ModelStorage.describe(bytes: 1_147_483_648) == "1.1 GB")
    }
}
