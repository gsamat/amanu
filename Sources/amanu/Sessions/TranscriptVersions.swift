import Foundation
import CryptoKit

/// The latest result remains at the recording root for CLI and hook compatibility.
/// Previous results have their own transcript, names, summary and processing state.
enum TranscriptVersions {
    static let requestFile = "transcribe.requested"

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
        let currentID = currentData.map(id)
        let archives = (try? fm.contentsOfDirectory(at: dir.appendingPathComponent("transcripts"),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        var versions = archives.compactMap { folder -> Version? in
            // A crash between snapshotting and replacing must not show the same result twice.
            guard folder.lastPathComponent != currentID else { return nil }
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
        let destination = archives.appendingPathComponent(id(data))
        if fm.fileExists(atPath: destination.path) { return destination }
        let staging = archives.appendingPathComponent(".\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for file in ["transcript.json", "transcript.md", SpeakerNames.file, "summary.md", "meta.json"] {
            let source = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: staging.appendingPathComponent(file)) }
        }
        if var meta = SessionState.read(staging) {
            meta["transcript_session_name"] = dir.lastPathComponent
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                .write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        }
        try fm.moveItem(at: staging, to: destination)
        return destination
    }

    /// Called only after recognition succeeds, while holding the session claim.
    /// An I/O failure restores the previous root artifacts and keeps the request.
    static func commit(_ transcript: Transcript, to dir: URL) throws {
        guard isRequested(dir) else { try transcript.write(to: dir); return }
        let fm = FileManager.default
        let archive = try archiveCurrent(dir)
        let files = ["transcript.md", "transcript.json", SpeakerNames.file, "meta.json"]
        let previous = Dictionary(uniqueKeysWithValues: files.map { ($0, try? Data(contentsOf: dir.appendingPathComponent($0))) })
        let manual = SpeakerNames.read(from: dir)?.manual ?? [:]
        let names = manual.isEmpty ? nil : SpeakerNames(speakers: manual)
        do {
            if let names { try names.write(to: dir) }
            else if fm.fileExists(atPath: dir.appendingPathComponent(SpeakerNames.file).path) {
                try fm.removeItem(at: dir.appendingPathComponent(SpeakerNames.file))
            }
            try transcript.write(to: dir)
            try SessionState.amend(dir, with: [
                SessionState.Key.summaryStale: archive != nil && fm.fileExists(atPath: dir.appendingPathComponent("summary.md").path) ? true : nil,
                SessionState.Key.speakersStatus: nil, SessionState.Key.summaryStatus: nil,
                SessionState.Key.speakersFailedFor: nil, SessionState.Key.summaryFailedFor: nil,
                SessionState.Key.speakersDeferrals: nil, SessionState.Key.summaryDeferrals: nil,
                SessionState.Key.transcriptionFailed: nil, SessionState.Key.transcriptionAttempts: nil,
                SessionState.Key.transcriptionDeferred: nil,
            ])
            try fm.removeItem(at: dir.appendingPathComponent(requestFile))
        } catch {
            for file in files {
                let url = dir.appendingPathComponent(file)
                if let data = previous[file] ?? nil { try? data.write(to: url, options: .atomic) }
                else { try? fm.removeItem(at: url) }
            }
            throw error
        }
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
        case "fishaudio": return "Fish Audio"
        case "auto": return localised("Automatic", "Автоматически")
        default: return id
        }
    }
}
