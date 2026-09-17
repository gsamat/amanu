import Foundation

/// A transcript as something outside amanu reads it.
///
/// The session's own transcript.md is written for the folder it lives in: it
/// opens with the session name and the engine that produced it, and every line
/// carries a clock. A file put beside a talk wants neither, so this renders the
/// same segments plainly, and leaves the speaker labels out when there is only
/// one voice to label. That is every dictaphone recording and every downloaded
/// lecture — `speaker:` in front of six hundred lines says nothing the file did
/// not already say. A diarizing engine that heard two people keeps its labels,
/// by name where a name is known.
enum TranscriptText {
    /// What `amanu transcribe` can leave beside a file. The session keeps
    /// transcript.json and transcript.md as always; these are for everything
    /// else — an editor, a video player, a script.
    enum Format: String, CaseIterable {
        case txt
        /// Subtitles, in the form every player reads: a numbered cue, a clock
        /// with a comma before the milliseconds.
        case srt
        /// The same cues for the web, where `<track>` takes WebVTT and nothing
        /// else: a header line, and a full stop before the milliseconds.
        case vtt
    }

    static func render(
        _ transcript: Transcript,
        as format: Format,
        names: SpeakerNames? = nil
    ) -> String {
        switch format {
        case .txt: return plain(transcript, names: names)
        case .srt, .vtt: return subtitles(transcript, as: format, names: names)
        }
    }

    static func plain(_ transcript: Transcript, names: SpeakerNames? = nil) -> String {
        let labelled = hasSeveralSpeakers(transcript)
        let lines = transcript.segments.compactMap { segment in
            line(segment, labelled: labelled, names: names)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func subtitles(
        _ transcript: Transcript,
        as format: Format = .srt,
        names: SpeakerNames? = nil
    ) -> String {
        let labelled = hasSeveralSpeakers(transcript)
        let web = format == .vtt
        var out: [String] = web ? ["WEBVTT", ""] : []
        var cue = 0
        for segment in transcript.segments {
            guard let text = line(segment, labelled: labelled, names: names) else { continue }
            cue += 1
            // A cue that ends before it starts is dropped by players, and a
            // recognizer emitting a word of zero length is not unheard of.
            let end = max(segment.end_ms, segment.start_ms + 1)
            out.append(String(cue))
            out.append("\(timecode(segment.start_ms, web: web)) --> \(timecode(end, web: web))")
            out.append(text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// One rendered line, or nil for a segment with nothing in it — an empty
    /// subtitle cue is worse than a missing one.
    private static func line(
        _ segment: Transcript.Segment,
        labelled: Bool,
        names: SpeakerNames?
    ) -> String? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard labelled else { return text }
        return "\(names?.name(for: segment.speaker) ?? segment.speaker): \(text)"
    }

    private static func hasSeveralSpeakers(_ transcript: Transcript) -> Bool {
        Set(transcript.segments.map(\.speaker)).count > 1
    }

    /// The subtitle clock: always hours, and the milliseconds after a comma
    /// in SRT or a full stop in WebVTT — the one character the two formats
    /// disagree on.
    private static func timecode(_ ms: Int, web: Bool) -> String {
        let ms = max(0, ms)
        return String(
            format: web ? "%02d:%02d:%02d.%03d" : "%02d:%02d:%02d,%03d",
            ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
