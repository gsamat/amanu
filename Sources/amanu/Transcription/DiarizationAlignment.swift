import Foundation

/// Maps real ASR word times to diarizer turns on the same source clock.
enum DiarizationAlignment {
    enum AlignmentError: Error, Equatable {
        case missingWordTiming
        case invalidWordTiming
    }

    struct Assignment: Codable, Sendable {
        let word: TranscriptWord
        let speakerID: String?
        let label: String
        let coverage: Double
        let runnerUpCoverage: Double
        let ambiguous: Bool
    }

    struct Result: Codable, Sendable {
        let segments: [Transcript.Segment]
        let assignments: [Assignment]
        /// Raw diarizer IDs, in order of first confirmed lexical appearance.
        let confirmedSpeakerIDs: [String]
    }

    private struct Interval {
        let speakerID: String
        var start: Double
        var end: Double
    }

    private static let roundingTolerance = 1.0 / 16_000 + 1e-9

    static func align(
        segments: [TranscriptSegment], turns: [SpeakerTurn],
        duration: TimeInterval, labelPrefix: String
    ) throws -> Result {
        guard duration.isFinite, duration >= 0 else { throw AlignmentError.invalidWordTiming }
        var words: [TranscriptWord] = []
        for segment in segments {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if segment.words?.isEmpty == false { throw AlignmentError.invalidWordTiming }
                continue
            }
            guard let lexical = segment.words, !lexical.isEmpty else {
                throw AlignmentError.missingWordTiming
            }
            // A partial native token payload must never make recognized text disappear.
            let lexicalText = lexical.map(\.text).joined().filter { !$0.isWhitespace }
            let segmentText = segment.text.filter { !$0.isWhitespace }
            guard lexicalText == segmentText else { throw AlignmentError.invalidWordTiming }
            words += lexical
        }

        var previousStart = -Double.infinity
        for word in words {
            guard word.start.isFinite, word.end.isFinite,
                  word.start >= -roundingTolerance,
                  word.start < word.end,
                  word.end <= duration + roundingTolerance,
                  word.start + roundingTolerance >= previousStart,
                  min(duration, word.end) > max(0, word.start),
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AlignmentError.invalidWordTiming }
            previousStart = word.start
        }

        // Union each raw voice first, so duplicate/overlapping diarizer windows
        // cannot create more than 100% coverage for one voice.
        var grouped: [String: [Interval]] = [:]
        for turn in turns {
            guard !turn.speakerID.isEmpty,
                  turn.start.isFinite, turn.end.isFinite,
                  turn.start >= -roundingTolerance,
                  turn.start < turn.end,
                  turn.end <= duration + roundingTolerance
            else { continue }
            grouped[turn.speakerID, default: []].append(Interval(
                speakerID: turn.speakerID,
                start: max(0, turn.start), end: min(duration, turn.end)))
        }
        var intervals: [Interval] = []
        for speakerID in grouped.keys.sorted() {
            let sorted = grouped[speakerID, default: []].sorted {
                $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
            }
            for interval in sorted {
                if let index = intervals.indices.last,
                   intervals[index].speakerID == speakerID,
                   interval.start <= intervals[index].end {
                    intervals[index].end = max(intervals[index].end, interval.end)
                } else {
                    intervals.append(interval)
                }
            }
        }
        intervals.sort {
            $0.start == $1.start
                ? ($0.end == $1.end ? $0.speakerID < $1.speakerID : $0.end < $1.end)
                : $0.start < $1.start
        }
        let expiry = intervals.indices.sorted { intervals[$0].end < intervals[$1].end }
        var active = Set<Int>()
        var nextStart = 0, nextExpiry = 0
        var assignments: [Assignment] = []
        var confirmedSpeakerIDs: [String] = []
        var confirmed = Set<String>()

        for word in words {
            while nextStart < intervals.count && intervals[nextStart].start < word.end {
                active.insert(nextStart)
                nextStart += 1
            }
            while nextExpiry < expiry.count && intervals[expiry[nextExpiry]].end <= word.start {
                active.remove(expiry[nextExpiry])
                nextExpiry += 1
            }
            let start = max(0, word.start), end = min(duration, word.end)
            let length = end - start
            var overlap: [String: Double] = [:]
            for index in active {
                let interval = intervals[index]
                let shared = max(0, min(end, interval.end) - max(start, interval.start))
                if shared > 0 { overlap[interval.speakerID, default: 0] += shared }
            }
            let ranked: [(String, Double)] = overlap.map { (key, value) in
                (key, value / length)
            }.sorted {
                $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
            }
            let best = ranked.first?.1 ?? 0
            let runnerUp = ranked.dropFirst().first?.1 ?? 0
            let speakerID: String? = best + 1e-9 >= 0.5
                && best - runnerUp + 1e-9 >= 0.2
                ? ranked.first?.0 : nil
            if let speakerID, confirmed.insert(speakerID).inserted {
                confirmedSpeakerIDs.append(speakerID)
            }
            assignments.append(Assignment(
                word: word, speakerID: speakerID, label: "", coverage: best,
                runnerUpCoverage: runnerUp,
                ambiguous: speakerID == nil && best >= 0.5 && runnerUp > 0))
        }

        let suffixes = Dictionary(uniqueKeysWithValues: confirmedSpeakerIDs.enumerated().map {
            ($0.element, $0.offset < 26
                ? String(UnicodeScalar(UInt8(65 + $0.offset)))
                : String($0.offset + 1))
        })
        assignments = assignments.map { assignment in
            let label = assignment.speakerID.flatMap { suffixes[$0] }.map {
                confirmedSpeakerIDs.count == 1 ? labelPrefix : "\(labelPrefix) \($0)"
            } ?? "\(labelPrefix) ?"
            return Assignment(
                word: assignment.word, speakerID: assignment.speakerID, label: label,
                coverage: assignment.coverage,
                runnerUpCoverage: assignment.runnerUpCoverage,
                ambiguous: assignment.ambiguous)
        }
        return Result(
            segments: buildSegments(assignments), assignments: assignments,
            confirmedSpeakerIDs: confirmedSpeakerIDs)
    }

    private static func buildSegments(_ assignments: [Assignment]) -> [Transcript.Segment] {
        var result: [Transcript.Segment] = []
        var current: [Assignment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            var text = ""
            for assignment in current {
                let piece = assignment.word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty
                    || piece.first.map({ ",.!?;:…)]}»'-".contains($0) }) == true
                    || text.last.map({ "([{'’-".contains($0) }) == true {
                    text += piece
                } else {
                    text += " " + piece
                }
            }
            result.append(Transcript.Segment(
                speaker: first.label,
                start_ms: Int((max(0, first.word.start) * 1000).rounded()),
                end_ms: Int((last.word.end * 1000).rounded()),
                text: text))
            current = []
        }

        for assignment in assignments {
            if let last = current.last,
               (assignment.label != last.label
                || assignment.word.start - last.word.end > 1
                || current.count >= 60) {
                flush()
            }
            current.append(assignment)
            if assignment.word.text.last.map({ ".?!".contains($0) }) == true {
                flush()
            }
        }
        flush()
        return result
    }
}
