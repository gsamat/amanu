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
    /// The engine used to pass the configured language straight through, which
    /// is a pin — and "meetings are mostly in Russian" is precisely the case
    /// where a pin is sometimes wrong. OpenAI has no expected_languages to
    /// narrow detection with instead, so the only safe answer is to say
    /// nothing and let the model listen.
    @Test("A language is named only when it cannot be the wrong one")
    func languageIsNamedOnlyWhenUnambiguous() {
        #expect(OpenAITranscriptionEngine.languageField(for: ["en"]) == "en")
        #expect(OpenAITranscriptionEngine.languageField(for: ["ru", "en"]) == nil)
        #expect(OpenAITranscriptionEngine.languageField(for: []) == nil)
    }

    /// The rule stated against the setting people actually change, so that a
    /// later change to what a choice expects can't quietly restore the pin.
    @Test("Choosing Russian sends no language at all")
    func russianIsNotPinned() {
        let expected = MeetingLanguages.expected(primary: "ru")
        #expect(OpenAITranscriptionEngine.languageField(for: expected) == nil)
        #expect(OpenAITranscriptionEngine.languageField(
            for: MeetingLanguages.expected(primary: "en")) == "en")
    }

    /// A response is only reused for the audio it came from: every piece of a
    /// sliced meeting has its own, and none of them is the whole meeting's —
    /// a first piece answered from the whole meeting's cache would carry an
    /// hour of text for three minutes of audio.
    @Test("Every piece of a sliced meeting has its own cached response")
    func cacheNames() async throws {
        let engine = try OpenAITranscriptionEngine(apiKey: "test-key")
        let folder = URL(fileURLWithPath: "/tmp/meeting")
        let audio = folder.appendingPathComponent("mixed.m4a")
        var pieces: [URL] = []
        for index in 0..<3 {
            pieces.append(await engine.cacheURL(in: folder, audio: audio, piece: index, of: 3))
        }
        #expect(Set(pieces).count == 3)
        #expect(!pieces.contains(await engine.cacheURL(in: folder, audio: audio, piece: 0, of: 1)))
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

    /// 1400 seconds is the ceiling an ordinary meeting reaches first, and the
    /// pieces are re-encoded at 64k whatever the mix was.
    @Test("Slice length keeps every piece under the duration limit and at 64k")
    func sliceDuration() throws {
        let limit = OpenAITranscriptionEngine.defaultRequestLimit
        // An hour at 25 kbit/s fits 25 MB whole, and is still cut by length.
        #expect(AudioSlicer.sliceLength(
            bytes: 3600 * 25_000 / 8, duration: 3600, limit: limit, maxDuration: 300) == 300)
        #expect(AudioSlicer.sliceLength(
            bytes: 200 * 25_000 / 8, duration: 200, limit: limit, maxDuration: 300) == nil)
        // Sized at a 40k source alone, a piece written at 64k would come out
        // 60% over its estimate.
        let length = try #require(AudioSlicer.sliceLength(
            bytes: 7200 * 40_000 / 8 + limit, duration: 7200, limit: limit))
        #expect(length * Double(AudioSlicer.encodedBitRate) / 8 < Double(limit))
    }

    @Test("Voice samples come from whoever talked longest, two to eight seconds each")
    func voiceChoice() throws {
        let decoded = try Self.response("""
        {"text":"","segments":[
          {"start":0,"end":12,"text":"a","speaker":"A"},
          {"start":12,"end":13,"text":"b","speaker":"B"},
          {"start":13,"end":16,"text":"b","speaker":"B"},
          {"start":16,"end":17.5,"text":"c","speaker":"C"},
          {"start":20,"end":24,"text":"d","speaker":"D"},
          {"start":24,"end":27,"text":"e","speaker":"E"},
          {"start":27,"end":29.5,"text":"f","speaker":"F"}]}
        """)
        let samples = OpenAITranscriptionEngine.voiceSamples(
            in: decoded.segments ?? [], labelPrefix: "1")

        // C never spoke for two seconds at once; four is the API's maximum.
        #expect(samples.map(\.name) == ["1A", "1B", "1D", "1E"])
        #expect(samples[0].start == 0)
        #expect(samples[0].length == 8)
        // B's sample is its longest utterance, not its first.
        #expect(samples[1].start == 13)
        #expect(samples[1].length == 3)
    }

    /// What the API sends with `stream=true`, trimmed from a real response of
    /// 28 October 2026.
    static let stream = """
    data: {"type":"transcript.text.segment","text":" Вот это я знаю.","speaker":"1B","start":0.0,"end":0.8,"id":"seg_0"}

    : ping - 2026-10-28 19:36:02.280424+00:00

    data: {"type":"transcript.text.segment","text":" Да, он живёт там.","speaker":"A","start":0.8,"end":2.25,"id":"seg_1"}

    data: {"type":"transcript.text.done","text":"Вот это я знаю. Да, он живёт там.","usage":{"type":"tokens","total_tokens":7285}}

    data: [DONE]

    """

    @Test("A streamed answer keeps a known voice's name and prefixes the rest")
    func streamedResponse() throws {
        let response = try #require(OpenAITranscriptionEngine.parse(Data(Self.stream.utf8)))
        let segments = OpenAITranscriptionEngine.segments(
            from: response, offset: 300, labelPrefix: "2", known: ["1B"])
        #expect(segments.map(\.speaker) == ["1B", "2A"])
        #expect(segments.map(\.text) == ["Вот это я знаю.", "Да, он живёт там."])
        #expect(segments[1].start == 300.8)
    }

    /// A stream cut off halfway is half a piece. Taken as an answer, it would
    /// be cached and never asked for again.
    @Test("A stream that stops short or reports an error is no answer")
    func unfinishedStream() {
        let cut = Self.stream.components(separatedBy: "data: {\"type\":\"transcript.text.done")[0]
        #expect(OpenAITranscriptionEngine.parse(Data(cut.utf8)) == nil)
        let failed = cut + #"data: {"type":"error","error":{"message":"server_error"}}"#
        #expect(OpenAITranscriptionEngine.parse(Data(failed.utf8)) == nil)
        let broken = Self.stream.replacingOccurrences(of: #""start":0.8,"#, with: "")
        #expect(OpenAITranscriptionEngine.parse(Data(broken.utf8)) == nil)
    }

    /// Past 1400 seconds the API refuses the piece, and the meeting with it.
    @Test("Pieces stay under the API's 1400 seconds")
    func durationLimit() {
        #expect(OpenAITranscriptionEngine.defaultDurationLimit < 1400)
    }

    @Test("Every piece after the first streams, and is told the first piece's voices in order")
    func requestFields() {
        let voices = [("1A", "data:a"), ("1B", "data:b")].map {
            OpenAITranscriptionEngine.Voice(name: $0.0, sample: $0.1)
        }
        let fields = OpenAITranscriptionEngine.fields(
            model: "gpt-4o-transcribe-diarize", expected: [], voices: voices)
        #expect(fields.contains { $0 == ("stream", "true") })
        #expect(fields.filter { $0.0 == "known_speaker_names[]" }.map(\.1) == ["1A", "1B"])
        #expect(fields.filter { $0.0 == "known_speaker_references[]" }.map(\.1) == ["data:a", "data:b"])
    }

    /// The first piece heard again can give its names to other voices, and a
    /// later piece cached under the old ones would then mean other people.
    @Test("A piece's cache depends on the voices' samples, not only their names")
    func cacheFollowsVoices() async throws {
        let engine = try OpenAITranscriptionEngine(apiKey: "test-key")
        let (folder, audio) = (URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/tmp/mixed.m4a"))
        func cache(_ sample: String?) async -> URL {
            await engine.cacheURL(
                in: folder, audio: audio, piece: 1, of: 3,
                voices: sample.map { [.init(name: "1A", sample: $0)] } ?? [])
        }
        #expect(await cache("data:a") != cache(nil))
        #expect(await cache("data:a") != cache("data:b"))
    }
}
