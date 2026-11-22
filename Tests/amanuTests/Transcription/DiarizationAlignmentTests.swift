import Foundation
import Testing

@testable import amanu

struct DiarizationAlignmentTests {
    private func segment(_ words: [(Double, Double, String)]) -> TranscriptSegment {
        TranscriptSegment(
            start: words.first?.0 ?? 0,
            end: words.last?.1 ?? 0,
            text: words.map(\.2).joined(separator: " "),
            words: words.map { TranscriptWord(start: $0.0, end: $0.1, text: $0.2) })
    }

    @Test("One long ASR segment keeps A-B-A voice changes and every word")
    func changesInsideSegment() throws {
        let asr = segment([(0, 1, "Привет,"), (2, 3, "API"), (4, 5, "да")])
        let turns = [
            SpeakerTurn(speakerID: "raw-a", start: 0, end: 1),
            SpeakerTurn(speakerID: "raw-b", start: 2, end: 3),
            SpeakerTurn(speakerID: "raw-a", start: 4, end: 5),
        ]
        let result = try DiarizationAlignment.align(
            segments: [asr], turns: turns, duration: 5, labelPrefix: "them")
        #expect(result.segments.map(\.speaker) == ["them A", "them B", "them A"])
        #expect(result.segments.map(\.text) == ["Привет,", "API", "да"])
        #expect(result.confirmedSpeakerIDs == ["raw-a", "raw-b"])
    }

    @Test("Union overlap cannot double count the same voice")
    func unionAndAmbiguity() throws {
        let asr = segment([(0, 1, "one"), (1, 2, "two"), (2, 3, "three")])
        let turns = [
            SpeakerTurn(speakerID: "a", start: 0, end: 0.25),
            SpeakerTurn(speakerID: "a", start: 0.1, end: 0.3),
            SpeakerTurn(speakerID: "b", start: 0.3, end: 1),
            SpeakerTurn(speakerID: "a", start: 1, end: 1.7),
            SpeakerTurn(speakerID: "b", start: 1.8, end: 2),
        ]
        let result = try DiarizationAlignment.align(
            segments: [asr], turns: turns, duration: 3, labelPrefix: "speaker")
        #expect(result.assignments.map(\.speakerID) == ["b", "a", nil])
        #expect(abs(result.assignments[0].coverage - 0.7) < 0.000_001)
        #expect(result.assignments[1].ambiguous == false)
        #expect(result.segments.map(\.speaker) == ["speaker A", "speaker B", "speaker ?"])
        #expect(result.confirmedSpeakerIDs == ["b", "a"])
    }

    @Test("Equal coverage and insufficient coverage stay unknown")
    func uncertainCoverage() throws {
        let asr = segment([(0, 1, "да"), (1, 2, "нет")])
        let turns = [
            SpeakerTurn(speakerID: "a", start: 0, end: 0.5),
            SpeakerTurn(speakerID: "b", start: 0.5, end: 1),
            SpeakerTurn(speakerID: "a", start: 1, end: 1.49),
        ]
        let result = try DiarizationAlignment.align(
            segments: [asr], turns: turns, duration: 2, labelPrefix: "them")
        #expect(result.assignments.map(\.speakerID) == [nil, nil])
        #expect(result.segments.map(\.speaker) == ["them ?"])
        #expect(result.segments.map(\.text) == ["да нет"])
        #expect(result.confirmedSpeakerIDs.isEmpty)
        #expect(result.assignments[0].ambiguous)
    }

    @Test("Invalid word timing requests turn fallback rather than a fabricated speaker")
    func invalidTiming() throws {
        for bad in [Double.nan, -0.1, 2.0] {
            let asr = TranscriptSegment(start: 0, end: 1, text: "word", words: [
                TranscriptWord(start: 0, end: bad, text: "word")])
            #expect(throws: DiarizationAlignment.AlignmentError.invalidWordTiming) {
                try DiarizationAlignment.align(
                    segments: [asr], turns: [], duration: 1, labelPrefix: "them")
            }
        }
        #expect(throws: DiarizationAlignment.AlignmentError.missingWordTiming) {
            try DiarizationAlignment.align(
                segments: [TranscriptSegment(start: 0, end: 1, text: "word")],
                turns: [], duration: 1, labelPrefix: "them")
        }
        #expect(throws: DiarizationAlignment.AlignmentError.invalidWordTiming) {
            try DiarizationAlignment.align(segments: [TranscriptSegment(
                start: 0, end: 1, text: "", words: [
                    TranscriptWord(start: 0, end: 1, text: "word")])],
                turns: [], duration: 1, labelPrefix: "them")
        }
    }

    @Test("More than 26 confirmed voices use the existing numeric suffix")
    func manyVoices() throws {
        let words = (0..<27).map { index in
            TranscriptWord(start: Double(index), end: Double(index) + 0.5, text: "w\(index)")
        }
        let asr = TranscriptSegment(start: 0, end: 26.5,
            text: words.map(\.text).joined(separator: " "), words: words)
        let turns = (0..<27).map { index in
            SpeakerTurn(speakerID: "id\(index)", start: Double(index), end: Double(index) + 0.5)
        }
        let result = try DiarizationAlignment.align(
            segments: [asr], turns: turns, duration: 27, labelPrefix: "them")
        #expect(result.segments.count == 27)
        #expect(result.segments[25].speaker == "them Z")
        #expect(result.segments[26].speaker == "them 27")
        #expect(result.confirmedSpeakerIDs.count == 27)
    }

    @Test("Legacy segments decode with absent word payload")
    func legacyCodable() throws {
        let original = try JSONDecoder().decode(TranscriptSegment.self,
            from: Data(#"{"start":0,"end":1,"text":"hello","speaker":null}"#.utf8))
        #expect(original.words == nil)
        let words = [TranscriptWord(start: 0, end: 1, text: "Привет")]
        let encoded = try JSONEncoder().encode(
            TranscriptSegment(start: 0, end: 1, text: "Привет", words: words))
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: encoded).words == words)
    }

    @Test("Settings have safe defaults and clamp non-finite/out-of-range thresholds")
    func settingsSnapshot() throws {
        #expect(DiarizationSettings() == DiarizationSettings(enabled: false, threshold: 0.6))
        #expect(DiarizationSettings(enabled: true, threshold: .nan).threshold == 0.6)
        #expect(DiarizationSettings(enabled: true, threshold: 0).threshold == 0.3)
        #expect(DiarizationSettings(enabled: true, threshold: 9).threshold == 1.2)
        #expect(try JSONDecoder().decode(DiarizationSettings.self,
            from: Data(#"{}"#.utf8)) == DiarizationSettings(model: .community1))
    }
}
