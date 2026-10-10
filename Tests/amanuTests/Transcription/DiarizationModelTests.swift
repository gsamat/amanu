import AVFoundation
import Foundation
import os
import Testing

@testable import amanu

struct DiarizationModelTests {
    @Test("Speaker-model setting defaults to Nemotron and flags an unknown persisted choice")
    func modelChoiceConfigContract() throws {
        let entry = try #require(SettingsSchema.everyEntry.first {
            $0.path == ["transcription", "diarization_model"]
        })
        #expect(entry.defaultValue as? String == "nemotron-3")
        #expect(Config.diarizationModel(in: nil) == .nemotron3)
        #expect(Config.diarizationModel(in: ["transcription": ["diarization_model": "ls-eend-ami"]]) == .lsEendAMI)
        #expect(Config.diarizationModel(in: ["transcription": ["diarization_model": "not-a-model"]]) == .nemotron3)
        #expect(Config.unusableValues(in: ["transcription": ["diarization_model": "not-a-model"]])
            .contains { if case .unusable(key: "transcription.diarization_model", found: _, expected: _) = $0 { true } else { false } })
    }

    @Test("Legacy persisted speaker requests retain Community-1 while new requests choose Nemotron")
    func legacyRequestModel() throws {
        let old = try JSONDecoder().decode(DiarizationState.Request.self,
            from: Data(#"{"engine":"parakeet","threshold":0.6,"explicit":false}"#.utf8))
        #expect(old.model == .community1)
        #expect(DiarizationState.Request(engine: "parakeet", threshold: 0.6).model == .nemotron3)
        let new = DiarizationState.Request(engine: "parakeet", threshold: 0.6, model: .lsEendAMI)
        #expect(try JSONDecoder().decode(DiarizationState.Request.self,
            from: JSONEncoder().encode(new)).model == .lsEendAMI)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DiarizationState.Request.self,
                from: Data(#"{"engine":"parakeet","threshold":0.6,"model":"unknown"}"#.utf8))
        }
    }

    @Test("Deleting one model does not remove its sibling and leased models remain busy")
    func independentModelDirectories() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-model-siblings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let community = parent.appendingPathComponent("diarization", isDirectory: true)
        let nemotron = parent.appendingPathComponent("diarization-nemotron-3", isDirectory: true)
        let lsEend = parent.appendingPathComponent("diarization-ls-eend-ami", isDirectory: true)
        for directory in [community, nemotron, lsEend] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("marker"))
        }
        let selected = DiarizationModelStore(model: .nemotron3, directory: nemotron, verifier: { _ in })
        let compact = DiarizationModelStore(model: .community1, directory: community, verifier: { _ in })
        let ami = DiarizationModelStore(model: .lsEendAMI, directory: lsEend, verifier: { _ in })
        try await selected.beginUse()
        await #expect(throws: DiarizationModelStore.StoreError.busy) { try await selected.delete() }
        try await compact.delete()
        #expect(FileManager.default.fileExists(atPath: nemotron.appendingPathComponent("marker").path))
        #expect(FileManager.default.fileExists(atPath: lsEend.appendingPathComponent("marker").path))
        await selected.endUse()
        try await ami.delete()
        #expect(FileManager.default.fileExists(atPath: nemotron.appendingPathComponent("marker").path))
    }

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

    private actor RequestedURL {
        private(set) var value: URL?

        func record(_ url: URL) { value = url }
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

    @Test("Each selectable model has complete pinned assets and the AMI notice")
    func selectableManifests() {
        for model in DiarizationModel.allCases {
            let assets = DiarizationModelStore.assets(for: model)
            #expect(!assets.isEmpty)
            #expect(Set(assets.map(\.path)).count == assets.count)
            #expect(assets.allSatisfy { $0.size > 0 && $0.sha256.count == 64 })
            #expect(assets.contains { $0.path.hasPrefix(model.primaryAssetPath) })
        }
        let ami = DiarizationModelStore.assets(for: .lsEendAMI)
        #expect(ami.count == 6)
        #expect(ami.first { $0.path.hasSuffix("model.mil") }?.sha256
                == "ba9a781d47ce033c41ad334e76d985fc067d7b6c338182f6e6d16e9b4289626b")
        #expect(ami.first { $0.path == "LICENSE" }?.sha256
                == "bcd00ee53d35b9a089a115fdb8eb6d8ea21d4161deb95c5cb9f91168fd0c7a33")
        let nemo = DiarizationModelStore.assets(for: .nemotron3)
        #expect(nemo.count == 1)
        #expect(nemo[0].sha256 == "08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1")
    }

    @Test("Community-1 keeps its pre-selection model fingerprint")
    func legacyCommunityFingerprint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-legacy-fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiarizationModelStore(model: .community1, directory: directory,
                                          verifier: { _ in })
        #expect(try await store.fingerprint()
                == "a5f266162b3237b566e22e79c868d2c1895c87f798f70a4b543c07ce883d7a47")
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
        }, fetch: { _, _, _ in
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

    @Test("Nemotron download requests the pinned root asset and keeps its local models path")
    func nemotronDownloadURL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-nemotron-url-\(UUID().uuidString)", isDirectory: true)
        let lock = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: lock)
        }
        let requested = RequestedURL()
        let store = DiarizationModelStore(model: .nemotron3, directory: directory,
                                          verifier: { _ in
            throw DiarizationModelStore.StoreError.missingOrCorrupt("fixture")
        }, fetch: { url, _, _ in
            await requested.record(url)
            throw CancellationError()
        })

        await #expect(throws: CancellationError.self) { try await store.download() }
        #expect(await requested.value?.absoluteString == "https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/f667ed73aee57d40cc39428eb768b4fd87a0a29e/Nemotron-3-Diarization.q8_0.gguf")
        #expect(DiarizationModelStore.assets(for: .nemotron3).map(\.path)
                == ["models/Nemotron-3-Diarization.q8_0.gguf"])
    }

    @Test("Nemotron reports received bytes before an incomplete file fails verification")
    func nemotronStreamingProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-nemotron-progress-\(UUID().uuidString)", isDirectory: true)
        let lock = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: lock)
        }
        let body = Data(repeating: 0x2a, count: 1_048_576)
        let server = StubHTTP { _, _ in .status(200, body: body) }
        let configuration = server.configuration
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let store = DiarizationModelStore(model: .nemotron3, directory: directory,
                                         fetch: { source, partial, progress in
            try await ModelDownloader.download(
                source: source, partial: partial, progress: progress,
                configuration: configuration)
        })

        await #expect(throws: DiarizationModelStore.StoreError.missingOrCorrupt(
            "models/Nemotron-3-Diarization.q8_0.gguf")) {
            try await store.download { fraction in fractions.withLock { $0.append(fraction) } }
        }

        let updates = fractions.withLock { $0 }
        #expect(updates.contains { $0 > 0 && $0 < 1 })
        #expect(updates.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(!(await store.isReady()))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Partial file progress uses immutable total across all Community-1 assets")
    func weightedMultiAssetProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-community-progress-\(UUID().uuidString)", isDirectory: true)
        let lock = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent).lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: lock)
        }
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let store = DiarizationModelStore(model: .community1, directory: directory,
                                         fetch: { _, _, progress in
            progress(.init(receivedBytes: 100, totalBytes: 243))
            throw CancellationError()
        })

        await #expect(throws: CancellationError.self) {
            try await store.download { fraction in fractions.withLock { $0.append(fraction) } }
        }

        let first = try #require(fractions.withLock { $0.first })
        #expect(abs(first - 100.0 / 22_024_318.0) < 0.00000001)
        #expect(first < 0.001)
    }

    @Test("Cancelling a transfer removes staging, releases the lease, and permits retry")
    func cancelledTransferCanRetry() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-nemotron-cancel-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("model-cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("previous-cache")
        try Data("keep".utf8).write(to: old)
        let started = StartSignal()
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let store = DiarizationModelStore(model: .nemotron3, directory: directory,
                                         fetch: { _, partial, progress in
            let attempt = attempts.withLock { value in value += 1; return value }
            if attempt == 1 {
                try Data(repeating: 0x2a, count: 4096).write(to: partial)
                progress(.init(receivedBytes: 4096, totalBytes: 107_012_128))
                await started.mark()
                try await Task.sleep(for: .seconds(60))
            }
            throw CancellationError()
        })
        let task = Task { try await store.download() }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(try Data(contentsOf: old) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("diarization-staging-") }.isEmpty)
        await #expect(throws: CancellationError.self) { try await store.download() }
        #expect(attempts.withLock { $0 } == 2)
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
        let modelName = ProcessInfo.processInfo.environment["AMANU_DIAR_MODEL_DOWNLOAD_MODEL"]
            ?? DiarizationModel.community1.rawValue
        let model = try #require(DiarizationModel(rawValue: modelName))
        let store = DiarizationModelStore(model: model, directory: directory)
        #expect(!(await store.isReady()), "Use a fresh disposable model directory")
        guard !(await store.isReady()) else { return }

        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        func stagingNames() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .filter { $0.hasPrefix("diarization-staging-") })
        }
        let stagingBefore = try stagingNames()
        let cancelledProgress = OSAllocatedUnfairLock(initialState: [Double]())
        let cancellable = OSAllocatedUnfairLock<Task<Void, Error>?>(initialState: nil)
        let interrupted = Task {
            try await store.download { fraction in
                cancelledProgress.withLock { $0.append(fraction) }
                if fraction > 0 && fraction < 1 {
                    cancellable.withLock { $0?.cancel() }
                }
            }
        }
        cancellable.withLock {
            $0 = interrupted
            if cancelledProgress.withLock({ !$0.isEmpty }) { $0?.cancel() }
        }
        await #expect(throws: CancellationError.self) { try await interrupted.value }
        cancellable.withLock { $0 = nil }
        #expect(cancelledProgress.withLock { $0.contains { $0 > 0 && $0 < 1 } })
        #expect(!(await store.isReady()))
        #expect(try stagingNames() == stagingBefore)

        let retryProgress = OSAllocatedUnfairLock(initialState: [Double]())
        try await store.download { fraction in retryProgress.withLock { $0.append(fraction) } }
        #expect(await store.isReady())
        #expect(try await store.fingerprint().count == 64)
        let fractions = retryProgress.withLock { $0 }
        #expect(fractions.contains { $0 > 0 && $0 < 1 })
        #expect(fractions.last == 1)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AMANU_DIAR_NATIVE_MODEL"] != nil
    && ProcessInfo.processInfo.environment["AMANU_DIAR_NATIVE_MODELS"] != nil
    && ProcessInfo.processInfo.environment["AMANU_DIAR_NATIVE_AUDIO"] != nil))
struct DiarizationNativeSelectionTests {
    private struct Turn: Encodable {
        let speaker: String
        let start: Double
        let end: Double
    }

    private struct Report: Encodable {
        let model: String
        let revision: String
        let modelFingerprint: String
        let audioSeconds: Double
        let prepareSeconds: Double
        let diarizationSeconds: Double
        let detectedSpeakerCount: Int
        let turns: [Turn]
    }

    @Test("Opt-in pinned native model produces valid speaker turns on public audio")
    func selectedModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        let modelName = try #require(environment["AMANU_DIAR_NATIVE_MODEL"])
        let model = try #require(DiarizationModel(rawValue: modelName))
        #expect(model != .community1)
        guard model != .community1 else { return }
        let modelsPath = try #require(environment["AMANU_DIAR_NATIVE_MODELS"])
        let audioPath = try #require(environment["AMANU_DIAR_NATIVE_AUDIO"])
        let permitted = ["/tmp/amanu-diarization-model-comparison/",
                         "/private/tmp/amanu-diarization-model-comparison/"]
        let models = URL(fileURLWithPath: modelsPath, isDirectory: true).resolvingSymlinksInPath()
        let audio = URL(fileURLWithPath: audioPath).resolvingSymlinksInPath()
        #expect(modelsPath.hasPrefix("/") && audioPath.hasPrefix("/"))
        #expect(permitted.contains { models.path.hasPrefix($0) })
        #expect(permitted.contains { audio.path.hasPrefix($0) })
        guard modelsPath.hasPrefix("/"), audioPath.hasPrefix("/"),
              permitted.contains(where: { models.path.hasPrefix($0) }),
              permitted.contains(where: { audio.path.hasPrefix($0) })
        else { return }

        let source = try AVAudioFile(forReading: audio)
        let duration = Double(source.length) / 16_000
        #expect(source.processingFormat.channelCount == 1)
        #expect(source.processingFormat.sampleRate == 16_000)
        #expect(duration > 0)
        guard source.processingFormat.channelCount == 1,
              source.processingFormat.sampleRate == 16_000, duration > 0 else { return }

        let store = DiarizationModelStore(model: model, directory: models)
        #expect(await store.isReady())
        let fingerprint = try await store.fingerprint()
        let runtime = DiarizationEngine(
            settings: DiarizationSettings(enabled: true, model: model), store: store)
        let start = ProcessInfo.processInfo.systemUptime
        try await runtime.prepare()
        let prepared = ProcessInfo.processInfo.systemUptime
        let turns: [SpeakerTurn]
        do {
            turns = try await runtime.diarize(audio)
        } catch {
            await runtime.release()
            throw error
        }
        let finished = ProcessInfo.processInfo.systemUptime
        await runtime.release()

        #expect(!turns.isEmpty)
        #expect(turns.allSatisfy {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                && $0.start < $0.end && $0.end <= duration
        })
        let speakerCount = Set(turns.map(\.speakerID)).count
        #expect(speakerCount <= (model == .nemotron3 ? 8 : 4))
        guard !turns.isEmpty, speakerCount <= (model == .nemotron3 ? 8 : 4),
              turns.allSatisfy({ $0.start.isFinite && $0.end.isFinite
                  && $0.start >= 0 && $0.start < $0.end && $0.end <= duration })
        else { return }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let reportURL = repository.appendingPathComponent(
            ".build/diarization-native-\(model.rawValue).json")
        let report = Report(
            model: model.rawValue, revision: model.revision,
            modelFingerprint: fingerprint, audioSeconds: duration,
            prepareSeconds: prepared - start, diarizationSeconds: finished - prepared,
            detectedSpeakerCount: speakerCount,
            turns: turns.map { Turn(speaker: $0.speakerID, start: $0.start, end: $0.end) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: reportURL.path)
        print("Native diarization numeric report written inside .build")
    }
}
