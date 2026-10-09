import Foundation
import Testing

@testable import amanu

struct DiarizationModelTests {
    private actor StartSignal {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?

        func mark() {
            started = true
            waiter?.resume()
            waiter = nil
        }

        func wait() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    @Test("Local diarization is opt-in and its threshold rejects malformed values")
    func settings() throws {
        #expect(!Config.localDiarizationEnabled(in: nil))
        #expect(Config.localDiarizationEnabled(in: ["transcription": ["local_diarization": true]])
            == Platform.supportsLocalModels)
        #expect(!Config.localDiarizationEnabled(in: ["transcription": ["local_diarization": "true"]]))
        #expect(Config.diarizationThreshold(in: nil) == 0.6)
        #expect(Config.diarizationThreshold(in: ["transcription": ["diarization_threshold": "0.8"]]) == 0.6)
        #expect(Config.diarizationThreshold(in: ["transcription": ["diarization_threshold": Double.nan]]) == 0.6)
        #expect(Config.diarizationThreshold(in: ["transcription": ["diarization_threshold": 0.1]]) == 0.3)
        #expect(Config.diarizationThreshold(in: ["transcription": ["diarization_threshold": 1.9]]) == 1.2)
        #expect(Config.unusableValues(in: ["transcription": ["local_diarization": 1]])
            .contains { if case .unusable(key: "transcription.local_diarization", found: _, expected: _) = $0 { true } else { false } })
        #expect(Config.unusableValues(in: ["transcription": ["diarization_threshold": true]])
            .contains { if case .unusable(key: "transcription.diarization_threshold", found: _, expected: _) = $0 { true } else { false } })
        if Platform.supportsLocalModels {
            let entry = try #require(SettingsSchema.sections.flatMap(\.entries).first {
                $0.path == ["transcription", "diarization_threshold"]
            })
            guard case .set(let value) = SettingsSchema.resolve(.text("1.9"), for: entry) else {
                Issue.record("The threshold field must accept and clamp a finite number")
                return
            }
            #expect(value as? Double == 1.2)
            guard case .invalid = SettingsSchema.resolve(.text("nan"), for: entry) else {
                Issue.record("The threshold field accepted a non-finite number")
                return
            }
        }
    }

    @Test("The pinned offline manifest includes every runtime component and attribution file")
    func manifestCoverage() {
        let paths = Set(DiarizationModelStore.assets.map(\.path))
        for required in ["Segmentation.mlmodelc/weights/weight.bin",
                         "Embedding.mlmodelc/weights/weight.bin",
                         "FBank.mlmodelc/weights/weight.bin",
                         "PLDA.mlmodelc/weights/weight.bin",
                         "PldaRho.mlmodelc/weights/weight.bin",
                         "plda-parameters.json", "xvector-transform.json",
                         "LICENSE", "NOTICE.md", "PROVENANCE.md", "provenance.json"] {
            #expect(paths.contains(required))
        }
        #expect(DiarizationModelStore.assets.allSatisfy {
            $0.size > 0 && $0.sha256.count == 64
        })
    }

    @Test("An incomplete model directory is never ready, and deletion respects an inference lease")
    func incompleteAndBusy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()
            .appendingPathComponent(".\(root.lastPathComponent).lock")) }
        let store = DiarizationModelStore(directory: root)
        #expect(!(await store.isReady()))
        let partial = root.appendingPathComponent("Segmentation.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([0]).write(to: partial.appendingPathComponent("weight.bin"))
        #expect(!(await store.isReady()))
        let leasedStore = DiarizationModelStore(directory: root, verifier: { _ in })
        try await leasedStore.beginUse()
        await #expect(throws: DiarizationModelStore.StoreError.busy) {
            try await leasedStore.delete()
        }
        await leasedStore.endUse()
        try await leasedStore.delete()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("Independent model-store descriptors exclude deletion and a cancelled download releases its lease")
    func processLeaseAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-lock-\(UUID().uuidString)", isDirectory: true)
        let lock = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: lock)
        }
        let first = DiarizationModelStore(directory: directory, verifier: { _ in })
        let second = DiarizationModelStore(directory: directory, verifier: { _ in })
        try await first.beginUse()
        await #expect(throws: DiarizationModelStore.StoreError.busy) {
            try await second.beginUse()
        }
        await #expect(throws: DiarizationModelStore.StoreError.busy) {
            try await second.delete()
        }
        await first.endUse()
        try await second.beginUse()
        await second.endUse()

        let signal = StartSignal()
        let downloading = DiarizationModelStore(directory: directory, verifier: { _ in
            throw DiarizationModelStore.StoreError.missingOrCorrupt("fixture")
        }, fetch: { _ in
            await signal.mark()
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        let task = Task { try await downloading.download() }
        await signal.wait()
        await #expect(throws: DiarizationModelStore.StoreError.busy) {
            try await second.delete()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await second.beginUse()
        await second.endUse()
    }

    @Test("Explicit pinned model download verifies every asset",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_DIAR_MODEL_DOWNLOAD_DIR"] != nil))
    func explicitDownloadSmoke() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["AMANU_DIAR_MODEL_DOWNLOAD_DIR"])
        #expect(path.hasPrefix("/"), "Use a disposable absolute directory outside the real home")
        guard path.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        #expect(!directory.path.hasPrefix(home.path + "/"),
                "The explicit download test must not write under the user's home")
        guard !directory.path.hasPrefix(home.path + "/") else { return }
        let store = DiarizationModelStore(directory: directory)
        try await store.download()
        #expect(await store.isReady())
        #expect(try await store.fingerprint().count == 64)
    }
}
