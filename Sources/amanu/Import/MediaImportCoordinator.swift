import CryptoKit
import Foundation

/// Main-actor buffer for files offered while the current batch is suspended
/// in AVFoundation. It deliberately coalesces them into the next sequential
/// batch instead of starting a second normalizer beside the first.
struct MediaImportPendingQueue {
    private var files: [URL] = []

    var isEmpty: Bool { files.isEmpty }

    mutating func enqueue(_ additions: [URL]) {
        files.append(contentsOf: additions)
    }

    mutating func takeAll() -> [URL] {
        defer { files.removeAll(keepingCapacity: true) }
        return files
    }

    mutating func removeAll() {
        files.removeAll(keepingCapacity: true)
    }
}

/// Turns files chosen in Finder into ordinary filesystem-backed sessions.
/// Importing is serial: normalization can be expensive, and running several
/// AVFoundation readers beside transcription only makes every item finish
/// later. Once a folder has its meta.json and is moved out of staging, the
/// existing transcription queue owns it like any recorded session.
actor MediaImportCoordinator {
    struct Imported: Sendable {
        let source: URL
        let session: URL
    }

    struct Duplicate: Sendable {
        let source: URL
        let existingSession: URL
    }

    struct Failure: Sendable {
        let source: URL
        let message: String
    }

    struct Result: Sendable {
        var imported: [Imported] = []
        var duplicates: [Duplicate] = []
        var failures: [Failure] = []
        var cancelled = false
    }

    struct Update: Sendable {
        enum Stage: Sendable { case checking, normalizing }

        let source: URL
        let index: Int
        let total: Int
        let stage: Stage
        /// Only normalization has a meaningful fraction. Hashing and media
        /// inspection report nil rather than presenting invented progress.
        let fraction: Double?
    }

    private let root: URL
    private let normalizer: any MediaNormalizing
    private let now: @Sendable () -> Date
    private var cancellationRequested = false
    private var activeHash: Task<String, Error>?
    private var activeNormalization: Task<Void, Error>?

    /// `removingStaleStaging` is what the app wants — it is the one importer
    /// on this Mac for the life of its process — and what a second process
    /// beside it must not do, see below.
    init(
        root: URL,
        normalizer: any MediaNormalizing = MediaNormalizer(),
        now: @escaping @Sendable () -> Date = Date.init,
        removingStaleStaging: Bool = true
    ) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.normalizer = normalizer
        self.now = now
        if removingStaleStaging { Self.removeStaleStaging(in: self.root) }
    }

    /// Staging folders have no completion marker and can only belong to a
    /// process that no longer exists when a fresh coordinator is created —
    /// true of the app at launch, and not of `amanu transcribe`, which may
    /// start while the app is halfway through an import of its own.
    /// Complete imported sessions never use this reserved prefix.
    private static func removeStaleStaging(in root: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(".import-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Import every supplied file in order. A bad item becomes one result and
    /// the next file still gets its turn; cancellation is different — it
    /// means stop the batch and remove the current unpublished staging folder.
    func importFiles(
        _ sources: [URL],
        progress: @escaping @Sendable (Update) -> Void = { _ in }
    ) async -> Result {
        cancellationRequested = false
        var result = Result()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for (offset, source) in sources.enumerated() {
            if cancellationRequested || Task.isCancelled {
                result.cancelled = true
                break
            }
            do {
                let outcome = try await importOne(
                    source,
                    index: offset + 1,
                    total: sources.count,
                    progress: progress)
                switch outcome {
                case .imported(let session):
                    result.imported.append(Imported(source: source, session: session))
                case .duplicate(let session):
                    result.duplicates.append(Duplicate(source: source, existingSession: session))
                }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append(Failure(source: source, message: "\(error)"))
            }
        }
        activeNormalization = nil
        activeHash = nil
        return result
    }

    /// Stop the current conversion. Files already published remain valid
    /// sessions; files after the current one have not been touched.
    func cancel() {
        cancellationRequested = true
        activeHash?.cancel()
        activeNormalization?.cancel()
    }

    private enum OneOutcome {
        case imported(URL)
        case duplicate(URL)
    }

    private func importOne(
        _ source: URL,
        index: Int,
        total: Int,
        progress: @escaping @Sendable (Update) -> Void
    ) async throws -> OneOutcome {
        progress(Update(
            source: source, index: index, total: total,
            stage: .checking, fraction: nil))
        let probe = try await normalizer.probe(source)
        try checkCancellation()
        let hashing = Task { try await Self.sha256(of: source) }
        activeHash = hashing
        let digest = try await hashing.value
        activeHash = nil
        try checkCancellation()
        if let existing = existingSession(with: digest, bytes: probe.sourceBytes) {
            return .duplicate(existing)
        }

        let staging = root.appendingPathComponent(
            ".import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: staging) }
        }

        let audio = staging.appendingPathComponent("source.m4a")
        let task = Task { [normalizer] in
            try await normalizer.normalize(source, to: audio) { fraction in
                progress(Update(
                    source: source, index: index, total: total,
                    stage: .normalizing, fraction: fraction))
            }
        }
        activeNormalization = task
        defer { activeNormalization = nil }
        try await task.value
        try checkCancellation()

        let importedAt = now()
        let meta: [String: Any] = [
            "title": source.deletingPathExtension().lastPathComponent,
            "started": ISO8601DateFormatter().string(from: importedAt),
            "ended": ISO8601DateFormatter().string(from: importedAt),
            "duration_seconds": max(1, Int(probe.duration.rounded(.up))),
            "trigger": "import",
            "stop_reason": "import",
            "files": ["source": "source.m4a"],
            "start_offset_ms": ["source": 0],
            "compressed": true,
            "import": [
                "original_filename": source.lastPathComponent,
                "source_bytes": probe.sourceBytes,
                "sha256": digest,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        // The completion marker is deliberately the last file written. A
        // scanner can never mistake half a normalized file for a session.
        try data.write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        try checkCancellation()

        let destination = uniqueDestination(for: source, at: importedAt)
        try FileManager.default.moveItem(at: staging, to: destination)
        published = true
        return .imported(destination.standardizedFileURL.resolvingSymlinksInPath())
    }

    private func checkCancellation() throws {
        if cancellationRequested || Task.isCancelled { throw CancellationError() }
    }

    private func existingSession(with digest: String, bytes: Int64) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        else { return nil }
        return entries.first { dir in
            guard
                let meta = SessionState.read(dir),
                let imported = meta["import"] as? [String: Any],
                imported["sha256"] as? String == digest
            else { return false }
            let storedBytes = (imported["source_bytes"] as? NSNumber)?.int64Value
            return storedBytes == bytes
        }
    }

    private func uniqueDestination(for source: URL, at date: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents(in: .current, from: date)
        let stamp = String(
            format: "%04d.%02d.%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0)
        let title = Self.safeFolderPart(source.deletingPathExtension().lastPathComponent)
        let base = title.isEmpty ? "\(stamp) Import" : "\(stamp) \(title)"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func safeFolderPart(_ source: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\n\r\t")
        let words = source.components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(words.prefix(80))
    }

    /// Hash without holding a meeting-sized file in memory.
    private static func sha256(of source: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                hash.update(data: chunk)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
