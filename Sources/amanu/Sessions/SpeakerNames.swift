import Foundation

/// The names put to a session's speaker labels, and where each one came from.
///
/// Lives beside the transcript rather than inside it. `transcript.json` is the
/// recognizer's own output and doubles as the queue's completion marker, so a
/// pass that renames people afterwards must not touch it — otherwise a crash
/// mid-rename leaves a session that looks transcribed but isn't, and there is
/// no way back to the raw labels when a name turns out wrong.
///
/// `transcript.md` is rendered from the two files together, which makes naming
/// re-runnable: change a name here, re-render, and nothing else in the session
/// has to know.
struct SpeakerNames: Codable {
    /// Where a name came from, in ascending order of authority.
    enum Source: String, Codable {
        /// The machine's account name, for the person doing the recording.
        case account
        /// `user_name` in the config.
        case config
        /// The naming pass.
        case model
        /// Typed by a person. Outranks the model permanently — a re-run leaves
        /// it alone, because someone who corrected a name once should not have
        /// to correct it again after every retry.
        case manual
    }

    struct Entry: Codable {
        /// nil when nobody could be identified: the label keeps printing as
        /// itself, which is honest in a way a guess isn't.
        var name: String?
        var source: Source
        /// The model's own confidence, kept for the record even though only
        /// `high` is ever applied.
        var confidence: String?
        /// The line that justified the name, and where it was said. Kept so a
        /// person reviewing a name can check it without re-reading the meeting.
        var quote: String?
        var at_ms: Int?

        init(
            name: String?,
            source: Source,
            confidence: String? = nil,
            quote: String? = nil,
            at_ms: Int? = nil
        ) {
            self.name = name
            self.source = source
            self.confidence = confidence
            self.quote = quote
            self.at_ms = at_ms
        }
    }

    static let file = "speakers.json"

    var created_at: String
    var backend: String?
    var model: String?
    /// Keyed by the transcript's own speaker label: "me", "them", "them A".
    var speakers: [String: Entry]

    init(
        created_at: String = ISO8601DateFormatter().string(from: Date()),
        backend: String? = nil,
        model: String? = nil,
        speakers: [String: Entry] = [:]
    ) {
        self.created_at = created_at
        self.backend = backend
        self.model = model
        self.speakers = speakers
    }

    static func read(from dir: URL) -> SpeakerNames? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
            return nil
        }
        return try? JSONDecoder().decode(SpeakerNames.self, from: data)
    }

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(
            to: dir.appendingPathComponent(Self.file), options: .atomic
        )
    }

    /// What to print for a label: the name if there is one, otherwise the
    /// label unchanged.
    func name(for label: String) -> String {
        speakers[label]?.name ?? label
    }

    /// Names a person typed, which a re-run must preserve.
    var manual: [String: Entry] {
        speakers.filter { $0.value.source == .manual }
    }

    var namedCount: Int {
        speakers.values.count { $0.name != nil }
    }

    /// Merge a fresh pass over an existing file: manual names win, and an
    /// existing name is only replaced by another actual name — a pass that
    /// comes back uncertain leaves what was already there.
    func merged(with fresh: SpeakerNames) -> SpeakerNames {
        var result = fresh
        for (label, entry) in speakers {
            if entry.source == .manual {
                result.speakers[label] = entry
            } else if entry.name != nil, result.speakers[label]?.name == nil {
                result.speakers[label] = entry
            }
        }
        return result
    }
}
