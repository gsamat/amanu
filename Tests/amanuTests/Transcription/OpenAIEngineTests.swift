import Foundation
import Testing

@testable import amanu

/// The parts of the OpenAI engine that don't need an API key: what comes back
/// from one request becomes segments on the session's clock, and a meeting too
/// long for one request is cut up and put back together.
struct OpenAIEngineTests {
    private static func response(_ json: String) throws -> OpenAITranscriptionEngine.Response {
        try JSONDecoder().decode(
            OpenAITranscriptionEngine.Response.self, from: Data(json.utf8))
    }

    @Test("Diarized segments keep their speakers and land on the session clock")
    func segmentsAreShifted() throws {
        let decoded = try Self.response("""
        {"task":"transcribe","duration":12.0,"text":"hello there",
         "segments":[
           {"type":"transcript.text.segment","id":"1","start":0.5,"end":2.0,
            "text":"hello","speaker":"A"},
           {"type":"transcript.text.segment","id":"2","start":3.0,"end":4.5,
            "text":"there","speaker":"B"}]}
        """)

        let segments = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 600, labelPrefix: nil)

        #expect(segments.count == 2)
        #expect(segments[0].start == 600.5)
        #expect(segments[0].end == 602.0)
        #expect(segments[0].speaker == "A")
        #expect(segments[1].text == "there")
        #expect(segments[1].start == 603.0)
    }

    /// Labels are per request, so the "A" of the second piece is a different
    /// person from the "A" of the first as far as anyone knows. Prefixing
    /// keeps them apart; merging them would hand two strangers one name.
    @Test("A sliced meeting keeps each piece's speakers apart")
    func labelsArePerSlice() throws {
        let decoded = try Self.response("""
        {"segments":[{"start":1.0,"end":2.0,"text":"go on","speaker":"A"}]}
        """)

        let first = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 0, labelPrefix: "1")
        let second = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 2400, labelPrefix: "2")

        #expect(first[0].speaker == "1A")
        #expect(second[0].speaker == "2A")
        #expect(second[0].start == 2401.0)
    }

    /// A response with speech but nothing the diarizer would split: keeping
    /// the flat text beats dropping the minutes it covers.
    @Test("A response with no segments keeps its text")
    func flatTextSurvives() throws {
        let decoded = try Self.response("""
        {"text":"  one long take  ","duration":30.0}
        """)

        let segments = OpenAITranscriptionEngine.segments(
            from: decoded, offset: 60, labelPrefix: nil)

        #expect(segments.count == 1)
        #expect(segments[0].text == "one long take")
        #expect(segments[0].start == 60)
        #expect(segments[0].end == 90)
    }

    @Test("An empty response yields nothing rather than an empty segment")
    func emptyIsEmpty() throws {
        let decoded = try Self.response("""
        {"text":"   ","duration":0,"segments":[]}
        """)
        #expect(OpenAITranscriptionEngine.segments(
            from: decoded, offset: 0, labelPrefix: nil).isEmpty)
    }

    /// The cache is the server's own answer, and a retry after a crash has to
    /// find every piece of it — so the name says which piece it is, and the
    /// ordinary one-request case keeps the plain name.
    @Test("Cached responses are named per piece only when there is more than one")
    func cacheNames() {
        #expect(OpenAITranscriptionEngine.cacheName(0, of: 1) == "transcript.openai.json")
        #expect(OpenAITranscriptionEngine.cacheName(0, of: 3) == "transcript.openai.1.json")
        #expect(OpenAITranscriptionEngine.cacheName(2, of: 3) == "transcript.openai.3.json")
    }

    /// 25 MB is the API's ceiling; the pieces have to come in under it with
    /// room for a bitrate that isn't perfectly constant.
    @Test("Slice length keeps every piece under the request limit")
    func sliceMath() {
        let limit = OpenAITranscriptionEngine.defaultRequestLimit

        // Under the limit: nothing to cut.
        #expect(AudioSlicer.sliceLength(
            bytes: 20 * 1_048_576, duration: 3000, limit: limit) == nil)

        // Two hours at the mix's own 64 kbit/s, which is about 55 MB.
        let bytes: Int64 = 55 * 1_048_576
        let length = try! #require(AudioSlicer.sliceLength(
            bytes: bytes, duration: 7200, limit: limit))
        let bytesPerSecond = Double(bytes) / 7200
        #expect(Double(length) * bytesPerSecond < Double(limit))
        // And not so cautious that it turns one meeting into a dozen uploads.
        #expect(length > 2000)
    }
}
