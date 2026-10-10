import CoreML
import CryptoKit
import Darwin
import FluidAudio
import Foundation
import os

/// Owns the explicit model download and the inference lease. The SDK loader can
/// fetch missing files, so inference loads only files verified here from disk.
actor DiarizationModelStore {
    enum StoreError: LocalizedError, Equatable {
        case busy
        case missingOrCorrupt(String)

        var errorDescription: String? {
            switch self {
            case .busy: "The speaker model is in use. Try again after processing finishes."
            case .missingOrCorrupt(let path): "The speaker model is incomplete or corrupt: \(path)."
            }
        }
    }

    static let shared = DiarizationModelStore(model: .community1, directory: processDirectory(for: .community1))
    private static let nemotron = DiarizationModelStore(model: .nemotron3, directory: processDirectory(for: .nemotron3))
    private static let lsEend = DiarizationModelStore(model: .lsEendAMI, directory: processDirectory(for: .lsEendAMI))

    private static func processDirectory(for model: DiarizationModel) -> URL {
        Home.process.url.appendingPathComponent(
            ".cache/amanu/\(model.assetDirectoryName)", isDirectory: true)
    }

    static func shared(for model: DiarizationModel) -> DiarizationModelStore {
        switch model {
        case .community1: shared
        case .nemotron3: nemotron
        case .lsEendAMI: lsEend
        }
    }
    static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    static let repository = "FluidInference/speaker-diarization-coreml"
    static let advertisedBytes = assets.reduce(0) { $0 + $1.size }

    struct Asset: Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    // SHA-256 and sizes are from the pinned repository's provenance.json;
    // the five notice files are pinned to the same immutable revision.
    static let assets: [Asset] = manifest.split(separator: "\n").map { line in
        let fields = line.split(separator: " ")
        precondition(fields.count == 3)
        return Asset(path: String(fields[0]), size: Int(fields[1])!, sha256: String(fields[2]))
    }

    private static let manifest = """
        Embedding.mlmodelc/analytics/coremldata.bin 243 8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682
        Embedding.mlmodelc/coremldata.bin 704 4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004
        Embedding.mlmodelc/metadata.json 2818 1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5
        Embedding.mlmodelc/model.mil 78432 22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3
        Embedding.mlmodelc/weights/weight.bin 13412288 99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b
        FBank.mlmodelc/analytics/coremldata.bin 243 0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a
        FBank.mlmodelc/coremldata.bin 853 57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759
        FBank.mlmodelc/metadata.json 3409 2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a
        FBank.mlmodelc/model.mil 15667 27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed
        FBank.mlmodelc/weights/weight.bin 1776896 9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36
        PLDA.mlmodelc/analytics/coremldata.bin 243 8e862420707c6fc86c5720adcbc811286235970cf5e0c5afdb7e10e03c937026
        PLDA.mlmodelc/coremldata.bin 535 3d5ddb4cf367ad23fb512587f751cddbe4cbf867f53c5395435e6719a6acfd20
        PLDA.mlmodelc/metadata.json 1975 95eab9a4c9ceb9b16bd36d3eee5530796a0cf78153547088c6c40e9e43999b98
        PLDA.mlmodelc/model.mil 5088 0c61b5f3fc8d482218ecf3f213ff42e40d6fc38265d3dcf5065da113974b25b8
        PLDA.mlmodelc/weights/weight.bin 199616 566c14f27af4ef1a4bdfb8ea875adeedd7026a85e1026659f48a3d305d51de0c
        PldaRho.mlmodelc/analytics/coremldata.bin 243 8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7
        PldaRho.mlmodelc/coremldata.bin 763 4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418
        PldaRho.mlmodelc/metadata.json 2749 b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945
        PldaRho.mlmodelc/model.mil 7613 83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041
        PldaRho.mlmodelc/weights/weight.bin 200192 80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36
        Segmentation.mlmodelc/analytics/coremldata.bin 243 64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb
        Segmentation.mlmodelc/coremldata.bin 812 ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc
        Segmentation.mlmodelc/metadata.json 3410 88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124
        Segmentation.mlmodelc/model.mil 43063 d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f
        Segmentation.mlmodelc/weights/weight.bin 5959360 c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2
        plda-parameters.json 89416 38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f
        xvector-transform.json 177499 f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688
        LICENSE 19759 736763bf08829e36266b8a3bebcc041ac68575424e976490671a7e6b43a525cf
        NOTICE.md 1925 0964a66893fa5c3a574758257d30d2944669f44eeed5784b30ec3bab902012b3
        PROVENANCE.md 3377 0032bc1b7d01b6af2bb6eb8548a39c9a28fe5c1909f74166bc2ea2eb1cc27df6
        README.md 4836 d0488f898df6da6e9d36f28b0704a65a13578d598c8685a9c5af0f5f8af13978
        provenance.json 10048 0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872
        """

    private static let lsEendManifest = """
        optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc/analytics/coremldata.bin 243 8c8d6032e92c8c43fe974f203d4a9041453e83932bbc133eaa00605afe3464b4
        optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc/coremldata.bin 1395 984dbda533de03f37b496d41400be4fb0cad97233106f868482ef79302526a38
        optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc/metadata.json 6999 11887907e88625e0281a328f159125399ddc794ac1e5af03e6ab03f8e4244a6e
        optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc/model.mil 239859 ba9a781d47ce033c41ad334e76d985fc067d7b6c338182f6e6d16e9b4289626b
        optimized/ami/500ms/ls_eend_ami_500ms.mlmodelc/weights/weight.bin 44426496 97952c32e939e275869cf202b0079b5563cf071ca90b2df10a123d1f56e702c5
        LICENSE 1072 bcd00ee53d35b9a089a115fdb8eb6d8ea21d4161deb95c5cb9f91168fd0c7a33
        """

    private static let nemotronManifest = """
        models/Nemotron-3-Diarization.q8_0.gguf 107012128 08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1
        """

    private static func manifest(for model: DiarizationModel) -> String {
        switch model {
        case .community1: manifest
        case .lsEendAMI: lsEendManifest
        case .nemotron3: nemotronManifest
        }
    }

    static func assets(for model: DiarizationModel) -> [Asset] {
        manifest(for: model).split(separator: "\n").map { line in
            let fields = line.split(separator: " ")
            precondition(fields.count == 3)
            return Asset(path: String(fields[0]), size: Int(fields[1])!, sha256: String(fields[2]))
        }
    }

    nonisolated let model: DiarizationModel
    nonisolated let directory: URL
    private let verifier: @Sendable (URL) throws -> Void
    private let fetch: VerifiedModelStore.Downloader
    private var inUse = false
    private var downloading = false
    private var leaseFD: Int32?

    init(model: DiarizationModel = .community1, directory: URL? = nil,
         verifier: (@Sendable (URL) throws -> Void)? = nil,
         fetch: @escaping VerifiedModelStore.Downloader = { source, partial, progress in
             try await ModelDownloader.download(
                 source: source, partial: partial, progress: progress)
         }) {
        self.model = model
        self.directory = directory ?? Home.current.url.appendingPathComponent(
            ".cache/amanu/\(model.assetDirectoryName)", isDirectory: true)
        self.verifier = verifier ?? { try DiarizationModelStore.verifyAssets(in: $0, model: model) }
        self.fetch = fetch
    }

    deinit {
        if let leaseFD {
            flock(leaseFD, LOCK_UN)
            close(leaseFD)
        }
    }

    func isReady() -> Bool { (try? verify()) != nil }

    nonisolated static func isReady(at directory: URL, model: DiarizationModel = .community1) -> Bool {
        (try? verifyAssets(in: directory, model: model)) != nil
    }

    /// Includes the exact weights and runtime options. Threshold belongs in
    /// the caller's options fingerprint so changing it preserves ASR.
    func fingerprint() throws -> String {
        try verify()
        let runtime: String
        switch model {
        case .community1:
            runtime = "FluidAudio-0.15.5|cpuAndNeuralEngine|FBank-cpuOnly|exclusiveSegments=false"
        case .lsEendAMI:
            runtime = "FluidAudio-0.15.5|LS-EEND-AMI500|cpuOnly|full-timeline"
        case .nemotron3:
            runtime = "NeMo-Speech.cpp-8642eaa5cc51efbc17ad0f3e433944ba858a873f|q8_0|v3-offline|Metal|chunked"
        }
        // Community-1 generations were persisted before model choice existed.
        // Keep their descriptor byte-for-byte so completed sessions remain replayable.
        let legacyDescriptor = model.revision + "|" + runtime + "|" + Self.manifest(for: model)
        let descriptor = model == .community1 ? legacyDescriptor : model.rawValue + "|" + legacyDescriptor
        return SHA256.hash(data: Data(descriptor.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func beginUse() throws {
        guard !inUse && !downloading else { throw StoreError.busy }
        try acquireLease()
        do { try verify() } catch {
            releaseLease()
            throw error
        }
        inUse = true
    }

    func endUse() {
        guard inUse else { return }
        inUse = false
        releaseLease()
    }

    func delete() throws {
        guard !inUse && !downloading else { throw StoreError.busy }
        try acquireLease()
        defer { releaseLease() }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// This is called only by the explicit Download control. A failed or
    /// cancelled transfer leaves the old verified set intact.
    func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !inUse && !downloading else { throw StoreError.busy }
        try acquireLease()
        defer { releaseLease() }
        if isReady() { progress(1); return }
        downloading = true
        defer { downloading = false }
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent("diarization-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var completed = 0
        let assets = Self.assets(for: model)
        let total = assets.reduce(0) { $0 + $1.size }
        let reported = OSAllocatedUnfairLock(initialState: 0.0)
        let report: @Sendable (Double, Bool) -> Void = { fraction, force in
            // Reserve 100% for a verified, atomically installed model.
            let fraction = min(0.999, max(0, fraction))
            let changed = reported.withLock { previous -> Bool in
                guard fraction > previous,
                      force || previous == 0 || fraction - previous >= 0.001
                else { return false }
                previous = fraction
                return true
            }
            if changed { progress(fraction) }
        }
        for asset in assets {
            try Task.checkCancellation()
            let remotePath = model == .nemotron3 ? "Nemotron-3-Diarization.q8_0.gguf" : asset.path
            let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(remotePath)")!
            let target = staging.appendingPathComponent(asset.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let verifiedBytes = completed
            try await fetch(url, target) { update in
                let received = min(max(update.receivedBytes, 0), Int64(asset.size))
                report(Double(verifiedBytes + Int(received)) / Double(total), false)
            }
            try Task.checkCancellation()
            try Self.verify(asset, in: staging)
            completed += asset.size
            if completed < total { report(Double(completed) / Double(total), true) }
        }
        try verify(in: staging)
        try Task.checkCancellation()
        let backup = directory.deletingLastPathComponent()
            .appendingPathComponent("diarization-old-\(UUID().uuidString)", isDirectory: true)
        let hadOld = fm.fileExists(atPath: directory.path)
        if hadOld { try fm.moveItem(at: directory, to: backup) }
        do {
            try fm.moveItem(at: staging, to: directory)
            if hadOld { try? fm.removeItem(at: backup) }
            progress(1)
        } catch {
            if hadOld { try? fm.moveItem(at: backup, to: directory) }
            throw error
        }
    }

    func loadModels() throws -> OfflineDiarizerModels {
        guard model == .community1 else { throw StoreError.missingOrCorrupt(model.primaryAssetPath) }
        guard inUse else { throw StoreError.busy }
        try verify()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly
        func load(_ name: String, _ config: MLModelConfiguration) throws -> MLModel {
            try MLModel(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("plda-parameters.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tensors = json?["tensors"] as? [String: Any]
        let psi = tensors?["psi"] as? [String: Any]
        guard let encoded = psi?["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              decoded.count > 0, decoded.count.isMultiple(of: MemoryLayout<Float>.size)
        else { throw StoreError.missingOrCorrupt("plda-parameters.json") }
        var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { destination in decoded.copyBytes(to: destination) }
        let values = floats.map { Double($0) }
        return try OfflineDiarizerModels(
            segmentationModel: load("Segmentation", configuration),
            fbankModel: load("FBank", fbankConfiguration),
            embeddingModel: load("Embedding", configuration),
            pldaRhoModel: load("PldaRho", configuration),
            pldaPsi: values,
            compilationDuration: 0)
    }

    private func verify() throws { try verify(in: directory) }

    private func verify(in root: URL) throws { try verifier(root) }

    /// The sibling file survives replacement or deletion of the model
    /// directory. `LOCK_NB` keeps a second GUI/CLI process from waiting while
    /// the first one holds Core ML models or downloads them.
    private func acquireLease() throws {
        guard leaseFD == nil else { throw StoreError.busy }
        let parent = directory.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { throw StoreError.busy }
        let lock = parent.appendingPathComponent(".\(directory.lastPathComponent).lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.busy }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw StoreError.busy
        }
        leaseFD = fd
    }

    private func releaseLease() {
        guard let leaseFD else { return }
        self.leaseFD = nil
        flock(leaseFD, LOCK_UN)
        close(leaseFD)
    }

    private static func verifyAssets(in root: URL, model: DiarizationModel) throws {
        for asset in assets(for: model) { try verify(asset, in: root) }
    }

    private static func verify(_ asset: Asset, in root: URL) throws {
        let path = root.appendingPathComponent(asset.path)
        guard let handle = try? FileHandle(forReadingFrom: path) else {
            throw StoreError.missingOrCorrupt(asset.path)
        }
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                count += data.count
                hash.update(data: data)
            }
        } catch {
            throw StoreError.missingOrCorrupt(asset.path)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == asset.size && digest == asset.sha256 else {
            throw StoreError.missingOrCorrupt(asset.path)
        }
    }
}
