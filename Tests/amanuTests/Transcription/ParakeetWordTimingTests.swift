import Foundation
import Testing

@testable import amanu

struct ParakeetWordTimingTests {
    @Test("Sentence and pause grouping retain exact model word times")
    func wordsSurviveGrouping() {
        let words = [
            TranscriptWord(start: 0.1, end: 0.4, text: "Привет,"),
            TranscriptWord(start: 0.45, end: 0.8, text: "мир."),
            TranscriptWord(start: 2.0, end: 2.2, text: "Да"),
        ]
        let segments = ParakeetEngine.segments(from: words)
        #expect(segments.count == 2)
        #expect(segments.flatMap { $0.words ?? [] } == words)
        #expect(segments.map(\.text) == ["Привет, мир.", "Да"])
        #expect(segments.map(\.start) == [0.1, 2.0])
    }
}
