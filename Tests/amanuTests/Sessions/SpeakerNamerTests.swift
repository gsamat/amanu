import Foundation
import Testing

@testable import amanu

/// The naming pass exists to be *refused* most of the time. Its failure mode
/// isn't leaving a speaker as "them A" — that's merely unhelpful — it's putting
/// the wrong person's name on somebody's words, which makes a transcript that
/// lies. These tests lean on the refusals.
struct SpeakerNamerTests {
    private static func seg(_ speaker: String, _ startMs: Int, _ text: String)
        -> Transcript.Segment {
        Transcript.Segment(
            speaker: speaker, start_ms: startMs, end_ms: startMs + 2000, text: text
        )
    }

    private static func transcript(_ segments: [Transcript.Segment]) -> Transcript {
        Transcript(
            engine: "assemblyai", model: "universal · ru",
            created_at: "2026-08-18T12:00:00Z", segments: segments
        )
    }

    private static let meeting = transcript([
        seg("me", 0, "Привет! Фёдор, слышно меня?"),
        seg("them A", 3000, "Да, слышно отлично."),
        seg("them B", 6000, "И меня тоже, привет."),
    ])

    private static func proposal(
        label: String, name: String?, confidence: String?, quote: String?
    ) -> SpeakerNamer.Proposal {
        // Decoded from JSON in production; built here so the gates are what's
        // under test rather than the decoder.
        let json = """
        {"label": \(encoded(label)), "name": \(encoded(name)),
         "confidence": \(encoded(confidence)), "quote": \(encoded(quote)), "at_ms": 3000}
        """
        return try! JSONDecoder().decode(
            SpeakerNamer.Proposal.self, from: Data(json.utf8)
        )
    }

    private static func encoded(_ value: String?) -> String {
        guard let value else { return "null" }
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: - the two gates

    @Test("A confident name backed by a real line is applied")
    func acceptsGroundedName() {
        let entry = SpeakerNamer.accept(
            Self.proposal(
                label: "them A", name: "Фёдор", confidence: "high",
                quote: "Фёдор, слышно меня?"
            ),
            in: Self.meeting
        )
        #expect(entry.name == "Фёдор")
        #expect(entry.source == .model)
    }

    /// The important one: a model that invents a name usually invents the line
    /// it came from too, and that is what makes this checkable at all.
    @Test("A name whose supporting quote isn't in the transcript is dropped")
    func rejectsFabricatedQuote() {
        let entry = SpeakerNamer.accept(
            Self.proposal(
                label: "them A", name: "Фёдор", confidence: "high",
                quote: "Меня зовут Фёдор, я руковожу разработкой"
            ),
            in: Self.meeting
        )
        #expect(entry.name == nil)
    }

    @Test("Anything short of high confidence leaves the label alone")
    func rejectsLowConfidence() {
        for confidence in ["medium", "low", nil] {
            let entry = SpeakerNamer.accept(
                Self.proposal(
                    label: "them A", name: "Фёдор", confidence: confidence,
                    quote: "Фёдор, слышно меня?"
                ),
                in: Self.meeting
            )
            #expect(entry.name == nil, "\(confidence ?? "unstated") should not be applied")
        }
    }

    /// A two-word minimum, because "да" appears in every meeting and would
    /// otherwise verify any name at all.
    @Test("A quote too short to prove anything doesn't count as evidence")
    func rejectsTrivialQuote() {
        let entry = SpeakerNamer.accept(
            Self.proposal(
                label: "them A", name: "Фёдор", confidence: "high", quote: "Да"
            ),
            in: Self.meeting
        )
        #expect(entry.name == nil)
    }

    @Test("Punctuation and case don't decide whether a quote was said")
    func quoteMatchingIsForgivingAboutTypography() {
        #expect(SpeakerNamer.quoteAppears("фёдор слышно меня", in: Self.meeting))
        #expect(SpeakerNamer.quoteAppears("Да, слышно — отлично!", in: Self.meeting))
        #expect(!SpeakerNamer.quoteAppears("слышно меня отлично", in: Self.meeting))
    }

    // MARK: - the owner's name

    @Test("An account name that reads as a person is used")
    func acceptsRealAccountName() {
        #expect(SpeakerNamer.personName(full: "Samat Galimov", login: "samat")
            == "Samat Galimov")
    }

    /// Everything macOS hands back that isn't a name. Each of these would
    /// otherwise be printed into a transcript as a speaker.
    @Test("Logins, device names and placeholders are refused")
    func rejectsNonNames() {
        let refused = [
            ("samat", "samat"),
            ("Samat", "samat"),
            ("Samat's MacBook Pro", "samat"),
            ("MacBook Air", "samat"),
            ("User", "user"),
            ("Administrator", "admin"),
            ("", "samat"),
            ("   ", "samat"),
            ("s4mat g4limov", "samat"),
        ]
        for (full, login) in refused {
            #expect(
                SpeakerNamer.personName(full: full, login: login) == nil,
                "\"\(full)\" should not be used as a speaker name"
            )
        }
    }

    // MARK: - parsing

    @Test("The mapping is found inside code fences and preamble")
    func parsesWrappedJSON() throws {
        let answer = """
        Sure — here's the mapping:

        ```json
        {"speakers": [{"label": "them A", "name": "Фёдор", "confidence": "high",
                       "quote": "Фёдор, слышно меня?", "at_ms": 0}]}
        ```
        """
        let proposals = try SpeakerNamer.parse(answer)
        #expect(proposals.count == 1)
        #expect(proposals.first?.name == "Фёдор")
    }

    @Test("An answer with no JSON in it is a malformed response, not a crash")
    func rejectsProse() {
        #expect(throws: LLMError.self) {
            try SpeakerNamer.parse("I couldn't work out who anyone was, sorry.")
        }
    }

    @Test("Labels come back in the order the meeting happened")
    func labelsAreInSpeakingOrder() {
        #expect(SpeakerNamer.orderedLabels(of: Self.meeting) == ["me", "them A", "them B"])
    }
}
