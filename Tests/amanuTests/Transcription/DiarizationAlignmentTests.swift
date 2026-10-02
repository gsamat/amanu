import Foundation
import Testing

@testable import amanu

/// The diarizer itself needs a model and an hour of audio; deciding which
/// voice a sentence belongs to needs neither. These are the arithmetic cases
/// that decide what a per-track transcript says when the local model has run —
/// the part where a wrong answer is invisible in the output, because "them A"
/// and "them B" swapped is still a plausible-looking transcript.
struct DiarizationAlignmentTests {
    private static func seg(_ start: Double, _ end: Double) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "…")
    }

    private static func voice(
        _ id: String, _ start: Double, _ end: Double
    ) -> DiarizationAlignment.Voice {
        DiarizationAlignment.Voice(id: id, start: start, end: end)
    }

    @Test("A segment inside one voice is that voice")
    func segmentInsideOneVoice() {
        let segment = Self.seg(1, 2)
        let voices = [Self.voice("S1", 0, 3)]
        #expect(DiarizationAlignment.voice(of: segment, among: voices) == "S1")
    }

    @Test("A segment straddling a voice change goes to the longer half")
    func mostOverlapWins() {
        // 4 s of S1 against 6 s of S2.
        let segment = Self.seg(0, 10)
        #expect(DiarizationAlignment.voice(
            of: segment,
            among: [Self.voice("S1", 0, 4), Self.voice("S2", 4, 10)]) == "S2")
        // And the other way round, so the answer follows the overlap and not
        // the order the voices were handed over in.
        #expect(DiarizationAlignment.voice(
            of: segment,
            among: [Self.voice("S1", 0, 6), Self.voice("S2", 6, 10)]) == "S1")
    }

    @Test("A tie goes to the voice that started first, whichever order it arrives in")
    func tieGoesToTheEarlierVoice() {
        let segment = Self.seg(0, 10)
        let later = Self.voice("S2", 5, 10)
        let earlier = Self.voice("S1", 0, 5)
        #expect(DiarizationAlignment.voice(of: segment, among: [later, earlier]) == "S1")
        #expect(DiarizationAlignment.voice(of: segment, among: [earlier, later]) == "S1")
    }

    @Test("Two voices that start together settle the same way whichever order they arrive in")
    func equalStartsAreDeterministic() {
        // Neither voice started first, so `start` alone cannot separate them
        // and the sort's own stability would be left to decide it. Both orders
        // must agree, or a rerun could relabel the same meeting.
        let segment = Self.seg(0, 4)
        let one = Self.voice("S1", 0, 2)
        let two = Self.voice("S2", 0, 2)
        #expect(DiarizationAlignment.voice(of: segment, among: [one, two]) == "S1")
        #expect(DiarizationAlignment.voice(of: segment, among: [two, one]) == "S1")
    }

    @Test("A segment no voice overlaps has no voice")
    func noOverlapIsNoVoice() {
        let segment = Self.seg(10, 12)
        #expect(DiarizationAlignment.voice(
            of: segment, among: [Self.voice("S1", 0, 5)]) == nil)
        // Touching but not overlapping is still nothing.
        #expect(DiarizationAlignment.voice(
            of: Self.seg(5, 7), among: [Self.voice("S1", 0, 5)]) == nil)
    }

    @Test("One voice on the side keeps the plain label")
    func oneVoiceStaysPlain() {
        let segments = [Self.seg(0, 2), Self.seg(3, 5)]
        #expect(DiarizationAlignment.labels(
            for: segments, voices: [Self.voice("S1", 0, 6)], side: "them")
            == ["them", "them"])
    }

    @Test("No voices at all keeps the plain label")
    func noVoicesStaysPlain() {
        let segments = [Self.seg(0, 2), Self.seg(3, 5)]
        #expect(DiarizationAlignment.labels(for: segments, voices: [], side: "them")
            == ["them", "them"])
    }

    @Test("Letters follow the transcript, not the diarizer's own order")
    func lettersFollowFirstAppearance() {
        // S2 is emitted first by the diarizer but spoken second; the first
        // sentence in the transcript is the one that becomes "them A". S1
        // speaks the last sentence too, as a diarizer's own segments do, so
        // its letter has to be found again rather than counted a second time.
        let segments = [Self.seg(0, 2), Self.seg(3, 5), Self.seg(6, 8)]
        let voices = [
            Self.voice("S2", 3, 5), Self.voice("S1", 0, 2), Self.voice("S1", 6, 8),
        ]
        #expect(DiarizationAlignment.labels(for: segments, voices: voices, side: "them")
            == ["them A", "them B", "them A"])
    }

    @Test("Three voices get A, B and C")
    func threeVoices() {
        let segments = [Self.seg(0, 2), Self.seg(3, 5), Self.seg(6, 8)]
        let voices = [
            Self.voice("S3", 6, 8), Self.voice("S1", 0, 2), Self.voice("S2", 3, 5),
        ]
        #expect(DiarizationAlignment.labels(for: segments, voices: voices, side: "them")
            == ["them A", "them B", "them C"])
    }

    @Test("A sentence the diarizer heard nobody under keeps the plain label")
    func unvoicedSentenceStaysPlain() {
        let segments = [Self.seg(0, 2), Self.seg(10, 12), Self.seg(3, 5)]
        let voices = [Self.voice("S1", 0, 2), Self.voice("S2", 3, 5)]
        #expect(DiarizationAlignment.labels(for: segments, voices: voices, side: "them")
            == ["them A", "them", "them B"])
    }

    @Test("The side is the caller's word, not a hard-coded them")
    func sideIsParameterised() {
        let segments = [Self.seg(0, 2), Self.seg(3, 5)]
        let voices = [Self.voice("S1", 0, 2), Self.voice("S2", 3, 5)]
        #expect(DiarizationAlignment.labels(for: segments, voices: voices, side: "speaker")
            == ["speaker A", "speaker B"])
    }

    @Test("The suffix runs A…Z, then falls back to numbers rather than wrapping")
    func suffixRunsPastZ() {
        #expect(SpeakerAttribution.suffix(0) == "A")
        #expect(SpeakerAttribution.suffix(1) == "B")
        #expect(SpeakerAttribution.suffix(25) == "Z")
        #expect(SpeakerAttribution.suffix(26) == "27")
        #expect(SpeakerAttribution.suffix(27) == "28")
    }
}
