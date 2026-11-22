import Foundation
import Testing

@testable import amanu

struct WhisperWordTimingTests {
    @Test("Split UTF-8 bytes and punctuation preserve the lexical text")
    func cyrillicAndPunctuation() {
        let greeting = Array(" Привет".utf8)
        let tokens = [
            WhisperRuntimeToken(bytes: Array(greeting.prefix(4)), start: 0.1, end: 0.2),
            WhisperRuntimeToken(bytes: Array(greeting.dropFirst(4)), start: 0.2, end: 0.6),
            WhisperRuntimeToken(bytes: Array("!".utf8), start: 0.6, end: 0.6),
            WhisperRuntimeToken(bytes: Array(" API".utf8), start: 0.7, end: 1.0),
        ]
        let words = WhisperWordTiming.words(
            from: tokens, segmentText: " Привет! API", duration: 1)
        #expect(words == [
            TranscriptWord(start: 0.1, end: 0.6, text: "Привет!"),
            TranscriptWord(start: 0.7, end: 1.0, text: "API"),
        ])
    }

    @Test("Invalid native times cannot be replaced by evenly spaced words")
    func invalidNativeTimes() {
        let token = WhisperRuntimeToken(bytes: Array(" hello".utf8), start: 0, end: 0)
        #expect(WhisperWordTiming.words(
            from: [token], segmentText: " hello", duration: 1) == nil)
        let multiword = WhisperRuntimeToken(
            bytes: Array(" hello world".utf8), start: 0, end: 1)
        #expect(WhisperWordTiming.words(
            from: [multiword], segmentText: " hello world", duration: 1) == nil)
    }

    @Test("Native special and timestamp IDs cannot enter lexical words")
    func specialTokenBoundary() {
        let firstSpecial: Int32 = 50_256
        let native: [(Int32, WhisperRuntimeToken)] = [
            (50_255, WhisperRuntimeToken(bytes: Array(" hello".utf8), start: 0, end: 0.5)),
            (50_256, WhisperRuntimeToken(bytes: Array("[_EOT_]".utf8), start: 0.5, end: 0.5)),
            (50_363, WhisperRuntimeToken(bytes: Array("[_TT_0]".utf8), start: 0.5, end: 0.5)),
        ]
        let lexical = native.compactMap { id, token in
            WhisperWordTiming.isLexicalToken(id, firstSpecialToken: firstSpecial)
                ? token : nil
        }
        #expect(WhisperWordTiming.words(
            from: lexical, segmentText: " hello", duration: 1) == [
                TranscriptWord(start: 0, end: 0.5, text: "hello")])
    }
}
