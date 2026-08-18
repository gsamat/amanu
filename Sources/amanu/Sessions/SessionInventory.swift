import Foundation

/// What is in the recordings folder and what has been done to each session.
///
/// Derived entirely from the disk — the files present, plus the session's own
/// `meta.json` — with no index of its own. That is a deliberate choice: the
/// recordings folder is somewhere a person goes with the Finder, deletes
/// things from, and moves folders out of, and any cache of what's there would
/// spend its life being wrong. Scanning a few hundred folders costs
/// milliseconds and is never stale.
enum SessionInventory {
    /// How one step of the pipeline stands for one session.
    enum Step: Equatable {
        case done
        /// Not attempted yet, and nothing says it can't be.
        case pending
        /// Attempted, but nothing could be reached. Comes back on its own.
        case deferred
        /// Attempted and won't work on a retry.
        case failed(String)
        /// Turned off in the config.
        case off

        var isOutstanding: Bool { self == .pending || self == .deferred }

        var label: String {
            switch self {
            case .done: return "done"
            case .pending: return "pending"
            case .deferred: return "deferred"
            case .failed: return "failed"
            case .off: return "off"
            }
        }
    }

    struct Item {
        let dir: URL
        /// The folder name, which is also its chronological sort key.
        let name: String
        let title: String?
        let started: Date?
        let duration: TimeInterval?
        let trigger: String?
        /// Engine and model from the transcript, once there is one.
        let engine: String?
        let transcript: Step
        let speakers: Step
        let summary: Step
        /// Named speakers over total speakers, once there is a transcript.
        let namedSpeakers: (named: Int, total: Int)?
        let sizeBytes: Int64

        /// Whether anything is left to do that a person might want to trigger.
        var isOutstanding: Bool {
            transcript.isOutstanding || speakers.isOutstanding || summary.isOutstanding
        }

        /// One line for a terminal listing.
        var summaryLine: String {
            let when = started.map { Item.stamp.string(from: $0) } ?? name
            let length = duration.map { " \(Int($0 / 60))m" } ?? ""
            let what = title.map { " \($0)" } ?? ""
            return "\(when)\(length)\(what)\n"
                + "    transcript: \(transcript.label)"
                + (engine.map { " (\($0))" } ?? "")
                + "  names: \(speakerLabel)"
                + "  summary: \(summary.label)"
        }

        private var speakerLabel: String {
            guard let counts = namedSpeakers, counts.total > 0 else { return speakers.label }
            return "\(speakers.label) \(counts.named)/\(counts.total)"
        }

        static let stamp: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
    }

    /// Every session under `root`, newest first — which is the order a person
    /// looking for "the meeting I just had" wants.
    static func scan(root: URL) -> [Item] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("meta.json").path
                )
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap(item(for:))
    }

    static func item(for dir: URL) -> Item? {
        guard let meta = SessionState.read(dir) else { return nil }
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }

        let calendar = meta["calendar"] as? [String: Any]
        let transcript = PostProcessor.readTranscript(dir)
        let names = SpeakerNames.read(from: dir)

        let transcriptStep: Step
        if transcript != nil {
            transcriptStep = .done
        } else if let failure = meta[SessionState.Key.transcriptionFailed] as? String {
            transcriptStep = .failed(failure)
        } else if !Config.transcriptionEnabled() {
            transcriptStep = .off
        } else {
            transcriptStep = .pending
        }

        var counts: (named: Int, total: Int)?
        if let transcript {
            let labels = SpeakerNamer.orderedLabels(of: transcript)
            counts = (named: names?.namedCount ?? 0, total: labels.count)
        }

        return Item(
            dir: dir,
            name: dir.lastPathComponent,
            title: (meta["title"] as? String) ?? (calendar?["title"] as? String),
            started: (meta["started"] as? String).flatMap(ISO8601DateFormatter().date(from:)),
            duration: (meta["duration_seconds"] as? Int).map(TimeInterval.init),
            trigger: meta["trigger"] as? String,
            engine: transcript.map { "\($0.engine)" },
            transcript: transcriptStep,
            speakers: step(
                dir: dir,
                artifact: exists(SpeakerNames.file),
                statusKey: SessionState.Key.speakersStatus,
                enabled: Config.speakerNames().enabled,
                blocked: transcriptStep != .done
            ),
            summary: step(
                dir: dir,
                artifact: exists("summary.md"),
                statusKey: SessionState.Key.summaryStatus,
                enabled: Config.summary().enabled && Config.summary().backend != "none",
                blocked: transcriptStep != .done
            ),
            namedSpeakers: counts,
            sizeBytes: size(of: dir)
        )
    }

    /// One step's state, from its artifact and the session's own note about it.
    ///
    /// A step whose input doesn't exist yet reads as `pending` rather than
    /// anything more definite: it hasn't failed, it simply hasn't had its turn.
    private static func step(
        dir: URL,
        artifact: Bool,
        statusKey: String,
        enabled: Bool,
        blocked: Bool
    ) -> Step {
        if artifact { return .done }
        if !enabled { return .off }
        guard let status = SessionState.value(dir, statusKey) as? String else {
            return .pending
        }
        if status == SessionState.deferred { return .deferred }
        return blocked ? .pending : .failed(status)
    }

    // MARK: - what a person needs to see to name a speaker

    /// A speaker, with enough of their speech to recognize who it was.
    struct Sample {
        let label: String
        let name: String?
        let source: SpeakerNames.Source?
        /// Their first words in the meeting — usually a greeting, which is
        /// where people say each other's names.
        let first: String
        /// Their longest turn, which is where the subject gives them away when
        /// the greeting doesn't.
        let longest: String
        let turns: Int
    }

    static func samples(transcript: Transcript, names: SpeakerNames?) -> [Sample] {
        SpeakerNamer.orderedLabels(of: transcript).map { label in
            let mine = transcript.segments.filter { $0.speaker == label }
            let entry = names?.speakers[label]
            return Sample(
                label: label,
                name: entry?.name,
                source: entry?.source,
                first: mine.first?.text ?? "",
                longest: mine.max { $0.text.count < $1.text.count }?.text ?? "",
                turns: mine.count
            )
        }
    }

    /// The opening of the meeting, as context above the per-speaker samples:
    /// hearing how it started is often what settles who was in it.
    static func opening(of transcript: Transcript, names: SpeakerNames?, lines: Int = 8) -> String {
        transcript.segments.prefix(lines).map { segment in
            let who = names?.name(for: segment.speaker) ?? segment.speaker
            return "\(who): \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func size(of dir: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}
