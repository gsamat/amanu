import Foundation
import Testing

@testable import amanu

/// The filter's risk isn't missing an echo — it's dropping something the user
/// actually said. These lean on that side: the keep cases matter more than the
/// drop cases.
struct EchoFilterTests {
    private static func seg(
        _ speaker: String, _ startMs: Int, _ endMs: Int, _ text: String
    ) -> Transcript.Segment {
        Transcript.Segment(speaker: speaker, start_ms: startMs, end_ms: endMs, text: text)
    }

    private static func speakers(_ segments: [Transcript.Segment]) -> [String] {
        EchoFilter.dropEchoes(segments).map { "\($0.speaker): \($0.text)" }
    }

    @Test("A mic segment repeating overlapping system speech is dropped")
    func dropsVerbatimEcho() {
        let out = Self.speakers([
            Self.seg("them", 1000, 4000, "So the quarterly reports are due on Friday."),
            Self.seg("me", 1100, 4100, "So the quarterly reports are due on Friday."),
        ])
        #expect(out == ["them: So the quarterly reports are due on Friday."])
    }

    /// The two tracks transcribe the same degraded audio slightly
    /// differently, which is why matching is fuzzy rather than exact.
    @Test("A near-miss transcription of the same speech is still dropped")
    func dropsImperfectEcho() {
        let out = Self.speakers([
            Self.seg("them", 1000, 4000, "we should review the data map before shipping"),
            Self.seg("me", 1100, 4100, "we should review the data mode before shipping"),
        ])
        #expect(out.count == 1)
    }

    @Test("Genuine cross-talk over far-end speech is kept")
    func keepsCrossTalk() {
        let out = Self.speakers([
            Self.seg("them", 1000, 4000, "So the quarterly reports are due on Friday."),
            Self.seg("me", 1500, 2500, "No, I I I do get you, but that slips the launch."),
        ])
        #expect(out.count == 2)
    }

    /// Short backchannels match almost anything by chance, so they only drop
    /// on an exact hit.
    @Test("Short backchannels survive unless they match exactly")
    func keepsBackchannels() {
        let out = Self.speakers([
            Self.seg("them", 1000, 4000, "and then we ship it, yeah, roughly then"),
            Self.seg("me", 1500, 1900, "mm hmm"),
        ])
        #expect(out.count == 2)
    }

    @Test("Mic speech outside any system segment is kept")
    func keepsNonOverlapping() {
        let out = Self.speakers([
            Self.seg("them", 1000, 4000, "So the quarterly reports are due on Friday."),
            Self.seg("me", 20000, 23000, "So the quarterly reports are due on Friday."),
        ])
        #expect(out.count == 2)
    }

    @Test("With no system track nothing is dropped")
    func noopWithoutSystemTrack() {
        let segments = [
            Self.seg("me", 1000, 4000, "just me talking here"),
            Self.seg("me", 5000, 8000, "still just me"),
        ]
        #expect(EchoFilter.dropEchoes(segments).count == 2)
    }

    /// The diarizing path yields "them A"/"them B", and its segments come from
    /// a single mixed file that can't contain the duplicate. The coordinator
    /// only runs the filter on the per-track path — this pins the filter's own
    /// behaviour if that ever changes.
    /// Regression: tokenizing with an `isASCII` guard reduced every Cyrillic
    /// segment to zero words, which the empty-words branch then classified as
    /// echo residue — deleting the user's whole side of a Russian meeting.
    @Test("Non-Latin speech is not mistaken for echo residue")
    func keepsCyrillicSpeech() {
        let out = Self.speakers([
            Self.seg("them", 4000, 12000, "Да, конечно. Бюджет мы согласовали вчера."),
            Self.seg("me", 4100, 8000, "Давайте обсудим статус проекта на этой неделе."),
        ])
        #expect(out.count == 2, "kept: \(out)")
    }

    @Test("A genuine Cyrillic echo is still dropped")
    func dropsCyrillicEcho() {
        let out = Self.speakers([
            Self.seg("them", 4000, 12000, "Бюджет мы согласовали вчера, осталось подписать."),
            Self.seg("me", 4100, 12100, "Бюджет мы согласовали вчера, осталось подписать."),
        ])
        #expect(out.count == 1, "kept: \(out)")
    }

    @Test("Suffixed far-side labels are not treated as the system track")
    func ignoresSuffixedLabels() {
        let segments = [
            Self.seg("them A", 1000, 4000, "So the quarterly reports are due on Friday."),
            Self.seg("me", 1100, 4100, "So the quarterly reports are due on Friday."),
        ]
        #expect(EchoFilter.dropEchoes(segments).count == 2)
    }
}
