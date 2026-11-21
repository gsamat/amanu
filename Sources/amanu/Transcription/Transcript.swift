import Foundation

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Render transcript.md, then write transcript.json as the completion
    /// marker. Both writes are atomic (temp file + rename), and writing the
    /// JSON last is what makes the ordering matter: resumePending treats its
    /// presence as "done", so writing it first meant a failed markdown write
    /// retired the session permanently with half its artifacts.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(self)

        try writeMarkdown(to: dir, names: SpeakerNames.read(from: dir))
        try json
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    /// Render transcript.md against whatever names are known, which is what
    /// makes naming re-runnable: the JSON keeps the recognizer's own labels
    /// for ever, and the readable file is regenerated from it whenever a name
    /// is learned or corrected.
    func writeMarkdown(to dir: URL, names: SpeakerNames?) throws {
        let title = SessionState.value(dir, "transcript_session_name") as? String ?? dir.lastPathComponent
        try Data(rendered(title: title, names: names).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    /// A copy with each label replaced by its readable name, for readers that
    /// take the speaker straight off the segment — the summarizer, mainly,
    /// which writes "Фёдор will send the contract" only if that is what it was
    /// given to read.
    ///
    /// An unnamed side stays `me` or `them` here rather than being translated:
    /// the summarizer's system prompt defines those two words, and a Russian
    /// interface used to hand it `я` and `они` instead.
    func named(with names: SpeakerNames?) -> Transcript {
        let labels = displayNames(names: names, translatingSides: false)
        return Transcript(
            engine: engine,
            model: model,
            created_at: created_at,
            segments: segments.map {
                Segment(
                    speaker: labels[$0.speaker] ?? $0.speaker,
                    start_ms: $0.start_ms,
                    end_ms: $0.end_ms,
                    text: $0.text
                )
            }
        )
    }

    /// Raw labels remain identifiers on disk. Readers see a saved name or a
    /// stable number in first-appearance order, without chunk namespaces.
    func displaySpeaker(label: String, names: SpeakerNames?) -> String {
        displayNames(names: names)[label] ?? label
    }

    private func displayNames(names: SpeakerNames?, translatingSides: Bool = true) -> [String: String] {
        Dictionary(uniqueKeysWithValues: SpeakerNamer.orderedLabels(of: self).enumerated().map { index, label in
            let name = names?.speakers[label]?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let readable: String
            if let name, !name.isEmpty {
                readable = name
            } else if label == "me" || label.hasPrefix("me ")
                || label == "them" || label.hasPrefix("them ") {
                readable = translatingSides ? SpeakerNames.described(label: label) : label
            } else {
                readable = localised("Participant \(index + 1)", "Участник \(index + 1)")
            }
            return (label, readable)
        })
    }

    func rendered(title: String, names: SpeakerNames?) -> String {
        let labels = displayNames(names: names)
        let unnamedLabels = displayNames(names: nil)
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        // A roster only earns its place when it says something the body
        // doesn't: which label a name stands for.
        let named = SpeakerNamer.orderedLabels(of: self).compactMap { label in
            names?.speakers[label]?.name.map { "\(unnamedLabels[label] ?? label) → \($0)" }
        }.sorted()
        if !named.isEmpty {
            lines.append("speakers: " + named.joined(separator: ", "))
        }
        lines.append("")
        if Self.formatsTurns(engine) {
            for paragraph in paragraphs(labels: labels) {
                lines.append("**[\(Self.clock(paragraph.start_ms))] \(paragraph.speaker):** \(paragraph.text)")
                lines.append("")
            }
        } else {
            for segment in segments {
                let who = labels[segment.speaker] ?? segment.speaker
                lines.append("**[\(Self.clock(segment.start_ms))] \(who):** \(segment.text)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The engines whose diarized output is shaped into turns for reading:
    /// both can return a short utterance for every few words, and both keep
    /// those timestamps in transcript.json untouched.
    static func formatsTurns(_ engine: String) -> Bool {
        engine == "assemblyai" || engine == "elevenlabs"
    }

    /// AssemblyAI can return one diarized utterance per word. Keep those
    /// timestamps in transcript.json, but present continuous speech as a turn.
    /// A brief interjection by another speaker does not split that turn.
    private func paragraphs(labels: [String: String]) -> [Paragraph] {
        var result: [Paragraph] = []
        var lastBySpeaker: [String: Int] = [:]
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = labels[segment.speaker] ?? segment.speaker
            if let index = lastBySpeaker[speaker],
               segment.start_ms - result[index].end_ms <= 1_500 {
                let separator = text.first.map { ",.!?;:…)]}»".contains($0) } == true ? "" : " "
                result[index].text += separator + text
                result[index].end_ms = max(result[index].end_ms, segment.end_ms)
            } else {
                lastBySpeaker[speaker] = result.count
                result.append(Paragraph(
                    speaker: speaker,
                    start_ms: segment.start_ms,
                    end_ms: segment.end_ms,
                    text: text))
            }
        }
        return result
    }

    private struct Paragraph {
        let speaker: String
        let start_ms: Int
        var end_ms: Int
        var text: String
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
