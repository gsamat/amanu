import Foundation
import Testing

@testable import amanu

struct TranscriptTextTests {
    private func transcript(_ segments: [Transcript.Segment]) -> Transcript {
        Transcript(
            engine: "parakeet",
            model: "parakeet-tdt-0.6b-v3-coreml",
            created_at: "2026-09-16T10:00:00Z",
            segments: segments)
    }

    @Test("A recording with one voice is plain text, with nobody labelled")
    func plainTextOfOneSpeaker() {
        let text = TranscriptText.plain(transcript([
            .init(speaker: "speaker", start_ms: 0, end_ms: 1_500, text: "Hello there."),
            .init(speaker: "speaker", start_ms: 1_500, end_ms: 3_000, text: "Second line."),
        ]))

        #expect(text == "Hello there.\nSecond line.\n")
    }

    @Test("Two voices are labelled, by name where a name is known")
    func plainTextOfSeveralSpeakers() {
        var names = SpeakerNames()
        names.speakers["them"] = SpeakerNames.Entry(name: "Fyodor", source: .manual)
        let text = TranscriptText.plain(
            transcript([
                .init(speaker: "me", start_ms: 0, end_ms: 1_000, text: "Ready?"),
                .init(speaker: "them", start_ms: 1_000, end_ms: 2_000, text: "Ready."),
            ]),
            names: names)

        #expect(text == "me: Ready?\nFyodor: Ready.\n")
    }

    @Test("Subtitles are numbered from one and timed in SRT's own clock")
    func subtitlesAreSRT() {
        let srt = TranscriptText.subtitles(transcript([
            .init(speaker: "speaker", start_ms: 0, end_ms: 1_500, text: "Hello there."),
            .init(speaker: "speaker", start_ms: 3_661_120, end_ms: 3_663_000, text: "Much later."),
        ]))

        #expect(srt == """
            1
            00:00:00,000 --> 00:00:01,500
            Hello there.

            2
            01:01:01,120 --> 01:01:03,000
            Much later.

            """)
    }

    @Test("WebVTT is the same cues under a header, with a full stop in the clock")
    func subtitlesCanBeWebVTT() {
        let vtt = TranscriptText.subtitles(transcript([
            .init(speaker: "speaker", start_ms: 0, end_ms: 1_500, text: "Hello there."),
        ]), as: .vtt)

        #expect(vtt == """
            WEBVTT

            1
            00:00:00.000 --> 00:00:01.500
            Hello there.

            """)
        #expect(TranscriptText.render(transcript([]), as: .vtt) == "WEBVTT\n")
    }

    @Test("An empty segment becomes no cue at all, and the numbering closes over it")
    func subtitlesSkipEmptySegments() {
        let srt = TranscriptText.subtitles(transcript([
            .init(speaker: "speaker", start_ms: 0, end_ms: 1_000, text: "   "),
            .init(speaker: "speaker", start_ms: 1_000, end_ms: 2_000, text: "Only line."),
        ]))

        #expect(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,000\nOnly line."))
        #expect(!srt.contains("\n2\n"))
    }

    @Test("A cue never ends before it starts")
    func subtitlesGiveZeroLengthSegmentsAnEnd() {
        let srt = TranscriptText.subtitles(transcript([
            .init(speaker: "speaker", start_ms: 500, end_ms: 500, text: "Blink."),
        ]))

        #expect(srt.contains("00:00:00,500 --> 00:00:00,501"))
    }
}
