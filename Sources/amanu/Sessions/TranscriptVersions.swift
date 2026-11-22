import Foundation
import CryptoKit

/// The latest result remains at the recording root for CLI and hook compatibility.
/// Previous results have their own transcript, names, summary and processing state.
enum TranscriptVersions {
    static let requestFile = "transcribe.requested"
    static let journalDirectory = ".transcript-commit"
    private static let transactionFiles: Set<String> = [
        "transcript.json", "transcript.md", SpeakerNames.file, "meta.json",
        "asr.json", "diarization.json", DiarizationArtifacts.candidateFile, requestFile,
    ]

    private static func rejectSymbolicLinks(_ urls: [URL]) throws {
        for url in urls where (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    struct Version {
        let dir: URL
        let engine: String
        let model: String
        let createdAt: Date
        let state: SessionInventory.Step
        let isCurrent: Bool
        let isRequest: Bool

        var title: String {
            let name = RecordingsEngineName.name(engine)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localised("en_US", "ru_RU"))
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            let stamp = formatter.string(from: createdAt)
            return isRequest ? "\(name) · \(state.described)" : "\(name) · \(stamp)"
        }
    }

    static func isRequested(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(requestFile).path)
    }

    static func read(_ dir: URL) -> [Version] {
        let fm = FileManager.default
        let currentData = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let currentID = currentData.map { archiveID($0, in: dir) }
        let archives = (try? fm.contentsOfDirectory(at: dir.appendingPathComponent("transcripts"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var versions = archives.compactMap { folder -> Version? in
            // A snapshot of the current generation is hidden, including one
            // saved under an older folder scheme. Identical transcript bytes
            // with a different bound speaker timeline remain distinct.
            if let currentData, let currentID,
               let archivedData = try? Data(contentsOf: folder.appendingPathComponent("transcript.json")),
               archivedData == currentData,
               archiveID(archivedData, in: folder) == currentID { return nil }
            return version(in: folder, current: false)
        }.sorted { ($0.createdAt, $0.dir.path) < ($1.createdAt, $1.dir.path) }
        if let current = version(in: dir, current: true) { versions.append(current) }
        if isRequested(dir) {
            let engine = (try? String(contentsOf: dir.appendingPathComponent(requestFile), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let created = (try? dir.appendingPathComponent(requestFile).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            versions.append(Version(dir: dir, engine: engine ?? Config.transcriptionEngine(), model: "",
                createdAt: created, state: requestState(dir), isCurrent: false, isRequest: true))
        }
        return versions
    }

    static func requestState(_ dir: URL) -> SessionInventory.Step {
        if let failure = SessionState.value(dir, SessionState.Key.transcriptionFailed) as? String {
            return .failed(failure)
        }
        if SessionState.value(dir, SessionState.Key.transcriptionDeferred) as? Bool == true { return .deferred }
        return Config.transcriptionEnabled() ? .pending : .off
    }

    private static func version(in dir: URL, current: Bool) -> Version? {
        guard let transcript = PostProcessor.readTranscript(dir) else { return nil }
        return Version(dir: dir, engine: transcript.engine, model: transcript.model,
            createdAt: creationDate(transcript.created_at),
            state: .done, isCurrent: current, isRequest: false)
    }

    private static func creationDate(_ value: String) -> Date {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    }

    private static func id(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct TimelineIdentity: Decodable {
        let schemaVersion: Int
        let transcriptSHA256: String
        let generationFingerprint: String
    }

    /// Keep the historical transcript JSON hash for legacy/unbound results.
    /// A valid speaker timeline adds its inference generation to the archive
    /// identity without changing the canonical transcript or sidecar hashes.
    private static func archiveID(_ data: Data, in dir: URL) -> String {
        let jsonHash = id(data)
        guard let timeline = try? Data(contentsOf: dir.appendingPathComponent(
            DiarizationArtifacts.timelineFile)),
              let identity = try? JSONDecoder().decode(TimelineIdentity.self, from: timeline),
              identity.schemaVersion == 1,
              identity.transcriptSHA256 == jsonHash,
              identity.generationFingerprint.count == 64,
              identity.generationFingerprint.allSatisfy({ $0.isHexDigit })
        else { return jsonHash }
        return id(Data("amanu-transcript-version-v1\u{1f}\(jsonHash)\u{1f}\(identity.generationFingerprint)".utf8))
    }

    /// Publish a complete snapshot with a directory rename. Hidden staging folders
    /// are ignored on recovery, and a retry of the same snapshot is idempotent.
    @discardableResult
    static func archiveCurrent(_ dir: URL) throws -> URL? {
        let fm = FileManager.default
        let current = dir.appendingPathComponent("transcript.json")
        guard fm.fileExists(atPath: current.path) else { return nil }
        let data = try Data(contentsOf: current)
        let archives = dir.appendingPathComponent("transcripts")
        try fm.createDirectory(at: archives, withIntermediateDirectories: true)
        let identity = archiveID(data, in: dir)
        let destination = archives.appendingPathComponent(identity, isDirectory: true)
        let target = archives.appendingPathComponent(identity)
        if fm.fileExists(atPath: destination.path) {
            guard let saved = try? Data(contentsOf: destination.appendingPathComponent("transcript.json")),
                  saved == data, archiveID(saved, in: destination) == identity
            else { throw CocoaError(.fileWriteFileExists) }
            return destination
        }
        let staging = archives.appendingPathComponent(".\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in ["transcript.json", "transcript.md", SpeakerNames.file, "summary.md", "meta.json",
                     "asr.json", "diarization.json"] {
            let source = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: staging.appendingPathComponent(file)) }
        }
        if var meta = SessionState.read(staging) {
            meta["transcript_session_name"] = dir.lastPathComponent
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        }
        try fm.moveItem(at: staging, to: target)
        return destination
    }

    /// Publish the files that identify one transcript generation under a
    /// journal. A process killed between renames leaves the old generation in
    /// the journal for the next claimant to restore.
    static func commit(
        _ transcript: Transcript, to dir: URL,
        sidecars: [String: Data?] = [:], metadata: [String: Any?] = [:],
        preserveRemoteNames: Bool = true
    ) throws {
        try SessionLock.withLock(dir) {
            try recover(dir)
            let fm = FileManager.default
            let oldJSON = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(transcript)
            if oldJSON == json, !isRequested(dir), sidecars.isEmpty, metadata.isEmpty { return }

            let archive = try archiveCurrent(dir)
            let manual = SpeakerNames.read(from: dir)?.manual ?? [:]
            let retained = preserveRemoteNames ? manual : manual.filter { $0.key == "me" }
            let names = retained.isEmpty ? nil : SpeakerNames(speakers: retained)
            let title = SessionState.value(dir, "transcript_session_name") as? String
                ?? dir.lastPathComponent
            guard var nextMeta = SessionState.read(dir) else {
                throw SessionState.StateError.unreadable(dir.appendingPathComponent("meta.json"))
            }
            if isRequested(dir) || oldJSON != nil {
                let reset: [String: Any?] = [
                    SessionState.Key.summaryStale: archive != nil && fm.fileExists(atPath: dir.appendingPathComponent("summary.md").path) ? true : nil,
                    SessionState.Key.speakersStatus: nil, SessionState.Key.summaryStatus: nil,
                    SessionState.Key.speakersFailedFor: nil, SessionState.Key.summaryFailedFor: nil,
                    SessionState.Key.speakersDeferrals: nil, SessionState.Key.summaryDeferrals: nil,
                    SessionState.Key.transcriptionFailed: nil, SessionState.Key.transcriptionAttempts: nil,
                    SessionState.Key.transcriptionDeferred: nil,
                ]
                for (key, value) in reset {
                    if let value { nextMeta[key] = value } else { nextMeta.removeValue(forKey: key) }
                }
            }
            for (key, value) in metadata {
                if let value { nextMeta[key] = value } else { nextMeta.removeValue(forKey: key) }
            }
            let meta = try JSONSerialization.data(withJSONObject: nextMeta, options: [.prettyPrinted, .sortedKeys])
            let namesData = try names.map { try encoder.encode($0) }
            var next: [String: Data?] = [
                "transcript.md": Data(transcript.rendered(title: title, names: names).utf8),
                "transcript.json": json,
                SpeakerNames.file: namesData,
                "meta.json": meta,
            ]
            for (file, data) in sidecars {
                guard ["asr.json", "diarization.json"].contains(file) else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                next.updateValue(data, forKey: file)
            }
            // Candidate text is private retry state. Its disappearance is part
            // of publishing the final generation, including crash recovery.
            next.updateValue(nil, forKey: DiarizationArtifacts.candidateFile)
            if isRequested(dir) { next.updateValue(nil, forKey: requestFile) }
            let journal = dir.appendingPathComponent(journalDirectory)
            let previous = journal.appendingPathComponent("previous")
            let staged = journal.appendingPathComponent("staged")
            try rejectSymbolicLinks([dir, journal, previous, staged]
                + next.keys.map { dir.appendingPathComponent($0) })
            try fm.createDirectory(at: previous, withIntermediateDirectories: true)
            do {
                try fm.createDirectory(at: staged, withIntermediateDirectories: true)
                var existing: [String] = []
                for file in next.keys.sorted() {
                    let old = dir.appendingPathComponent(file)
                    if fm.fileExists(atPath: old.path) {
                        try fm.copyItem(at: old, to: previous.appendingPathComponent(file))
                        existing.append(file)
                    }
                    if let data = next[file] ?? nil {
                        try data.write(to: staged.appendingPathComponent(file), options: .atomic)
                    }
                }
                try encoder.encode(Journal(files: next.keys.sorted(), existing: existing))
                    .write(to: journal.appendingPathComponent("manifest.json"), options: .atomic)
                for file in next.keys.sorted() {
                    let target = dir.appendingPathComponent(file)
                    if let data = next[file] ?? nil {
                        try data.write(to: target, options: .atomic)
                    } else if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: target)
                    }
                }
                try Data().write(to: journal.appendingPathComponent("published"), options: .atomic)
                try fm.removeItem(at: journal)
            } catch {
                try? recover(dir)
                throw error
            }
        }
    }

    private struct Journal: Codable {
        let files: [String]
        let existing: [String]
    }

    /// Called under the session claim before interpreting transcript.json.
    static func recover(_ dir: URL) throws {
        let fm = FileManager.default
        let journal = dir.appendingPathComponent(journalDirectory)
        try rejectSymbolicLinks([dir, journal])
        guard fm.fileExists(atPath: journal.path) else { return }
        let previous = journal.appendingPathComponent("previous")
        let staged = journal.appendingPathComponent("staged")
        let manifestURL = journal.appendingPathComponent("manifest.json")
        let published = journal.appendingPathComponent("published")
        try rejectSymbolicLinks([previous, staged, manifestURL, published])
        if fm.fileExists(atPath: published.path) {
            try fm.removeItem(at: journal)
            return
        }
        guard fm.fileExists(atPath: manifestURL.path) else {
            // Publication never began: only private staging may exist.
            try fm.removeItem(at: journal)
            return
        }
        let manifest = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: manifestURL))
        guard Set(manifest.files).count == manifest.files.count,
              Set(manifest.existing).count == manifest.existing.count,
              Set(manifest.files).isSubset(of: transactionFiles),
              Set(manifest.existing).isSubset(of: Set(manifest.files))
        else { throw CocoaError(.fileReadCorruptFile) }
        try rejectSymbolicLinks(manifest.files.flatMap {
            [dir.appendingPathComponent($0), previous.appendingPathComponent($0)]
        })
        for file in manifest.files {
            let target = dir.appendingPathComponent(file)
            if manifest.existing.contains(file) {
                let old = try Data(contentsOf: previous.appendingPathComponent(file))
                try old.write(to: target, options: .atomic)
            } else if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
        }
        try fm.removeItem(at: journal)
    }
}

private enum RecordingsEngineName {
    static func name(_ id: String) -> String {
        switch id {
        case "local", "parakeet": return "Parakeet"
        case "whisper": return "Whisper"
        case "gigaam": return "GigaAM"
        case "assemblyai": return "AssemblyAI"
        case "openai": return "OpenAI"
        case "elevenlabs": return "ElevenLabs"
        case "auto": return localised("Automatic", "Автоматически")
        default: return id
        }
    }
}
