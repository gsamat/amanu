import Foundation
import FluidAudio
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

    @Test("A file-backed SDK result with duration zero retains valid token times")
    func zeroSDKDurationKeepsWords() {
        let result = ASRResult(
            text: "hello world", confidence: 0.9, duration: 0, processingTime: 0.1,
            tokenTimings: [
                TokenTiming(token: "▁hello", tokenId: 1, startTime: 0.1, endTime: 0.4,
                            confidence: 0.9),
                TokenTiming(token: "▁world", tokenId: 2, startTime: 0.5, endTime: 0.8,
                            confidence: 0.9),
            ])
        let segments = ParakeetEngine.transcript(from: result, audioDuration: 1)
        #expect(segments.count == 1)
        #expect(segments[0].words == [
            TranscriptWord(start: 0.1, end: 0.4, text: "hello"),
            TranscriptWord(start: 0.5, end: 0.8, text: "world"),
        ])
        #expect(segments[0].start == 0.1)
        #expect(segments[0].end == 0.8)
    }

    @Test("Zero SDK duration uses real audio bounds for coarse fallback")
    func zeroSDKDurationCoarseFallback() {
        let missingWords = ASRResult(
            text: "hello", confidence: 0.9, duration: 0, processingTime: 0.1)
        let coarse = ParakeetEngine.transcript(from: missingWords, audioDuration: 1)
        #expect(coarse.count == 1)
        #expect(coarse[0].start == 0)
        #expect(coarse[0].end == 1)

        let invalidWords = ASRResult(
            text: "hello", confidence: 0.9, duration: 0, processingTime: 0.1,
            tokenTimings: [TokenTiming(
                token: "▁hello", tokenId: 1, startTime: .nan, endTime: 0.5,
                confidence: 0.9)])
        let fallback = ParakeetEngine.transcript(from: invalidWords, audioDuration: 1)
        #expect(fallback.count == 1)
        #expect(fallback[0].start == 0)
        #expect(fallback[0].end == 1)

        let empty = ASRResult(text: "  ", confidence: 0, duration: 0, processingTime: 0.1)
        #expect(ParakeetEngine.transcript(from: empty, audioDuration: 1).isEmpty)
    }
}
