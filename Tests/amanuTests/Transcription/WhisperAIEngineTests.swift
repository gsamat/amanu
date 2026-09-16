import Foundation
import Testing

@testable import amanu

/// The places WhisperAI differs from the AssemblyAI engine it was copied
/// from. The parts that are identical are covered by `AssemblyAIEngineTests`
/// and by `ProviderTimestamps`, which both engines now share.
struct WhisperAIEngineTests {
    /// With no language configured, nothing is said about language at all.
    @Test("A transcription request asks for detection, channel separation and diarization")
    func requestDetectsTheLanguageAndSeparatesChannels() {
        let body = WhisperAIEngine.requestBody(
            audioURL: "https://api.whisperai.test/v1/uploads/up_1",
            expectedLanguages: [],
            speechModel: nil)

        #expect(body["audio_url"] as? String == "https://api.whisperai.test/v1/uploads/up_1")
        #expect(body["multichannel"] as? Bool == true)
        #expect(body["speaker_labels"] as? Bool == true)
        #expect(body["language_detection"] as? Bool == true)
        #expect(body["prompt"] == nil)
        #expect(body["speech_model"] == nil)
    }

    /// The expectation is a hint and must stay one.
    ///
    /// `language_code` is the only language field this API takes, and it is a
    /// hard pin — the failure mode Amanu guards against everywhere else,
    /// because a pin on the wrong language produces a fluent transcript of a
    /// meeting that did not happen. The shortlist goes into `prompt` instead,
    /// and detection stays on to overrule it.
    @Test("The expected languages are a prompt hint, never a pin")
    func expectedLanguagesAreAHintAndNotAPin() {
        let body = WhisperAIEngine.requestBody(
            audioURL: "https://api.whisperai.test/v1/uploads/up_1",
            expectedLanguages: ["ru", "en"],
            speechModel: nil)

        #expect(body["prompt"] as? String == "A recorded meeting. Expected languages: ru, en.")
        #expect(body["language_detection"] as? Bool == true)
        #expect(body["language_code"] == nil)
        // AssemblyAI's shortlist field would be a 422 here: the parameters are
        // a closed object, so an unknown key is refused rather than ignored.
        #expect(body["language_detection_options"] == nil)
    }

    /// Names from the calendar are worth sending; the addresses mixed in with
    /// them are not. An attendee with no display name in the event arrives as
    /// their email, which nobody says out loud — so it would teach the
    /// recogniser nothing and hand a vendor somebody's address for it.
    @Test("Only attendees that are names become vocabulary")
    func addressesNeverBecomeVocabulary() {
        let terms = SpokenTerms.from(attendees: [
            "Samat Galimov",
            "someone@example.com",
            "  Maxim Chistyakov  ",
            "samat galimov",
            "",
        ])

        #expect(terms == ["Samat Galimov", "Maxim Chistyakov"])
    }

    @Test("The vocabulary is capped at the documented ceiling")
    func vocabularyIsBounded() {
        let many = (0..<150).map { "Person \($0)" }
        #expect(SpokenTerms.from(attendees: many).count == SpokenTerms.limit)
    }

    @Test("Attendee names are sent as custom vocabulary, and nothing is sent without them")
    func keytermsTravelWithTheRequest() {
        let withNames = WhisperAIEngine.requestBody(
            audioURL: "https://api.whisperai.test/v1/uploads/up_1",
            expectedLanguages: [],
            keyterms: ["Samat Galimov", "Maxim Chistyakov"],
            speechModel: nil)
        #expect(withNames["keyterms_prompt"] as? [String]
            == ["Samat Galimov", "Maxim Chistyakov"])

        let without = WhisperAIEngine.requestBody(
            audioURL: "https://api.whisperai.test/v1/uploads/up_1",
            expectedLanguages: [],
            speechModel: nil)
        #expect(without["keyterms_prompt"] == nil)
    }

    @Test("A configured speech model is sent and a mono file asks for no channels")
    func speechModelAndMonoAreHonoured() {
        let body = WhisperAIEngine.requestBody(
            audioURL: "https://api.whisperai.test/v1/uploads/up_1",
            expectedLanguages: [],
            speechModel: "whisperai-pro",
            multichannel: false)

        #expect(body["speech_model"] as? String == "whisperai-pro")
        #expect(body["multichannel"] == nil)
    }

    /// Two cloud engines writing one filename would have the second read the
    /// first one's answer out of the cache and render it as its own.
    @Test("The cache is named for this provider and not the other one")
    func cacheHasItsOwnName() {
        let cache = WhisperAIEngine.cacheURL(for: URL(fileURLWithPath: "/tmp/meeting/mix.m4a"))
        #expect(cache.lastPathComponent == "transcript.whisperai.multichannel.json")
        #expect(cache != AssemblyAIEngine.cacheURL(for: URL(fileURLWithPath: "/tmp/meeting/mix.m4a")))
    }

    /// Amanu reads the side off the front of the speaker label, so a bare `A`
    /// has to be joined to its channel first. The published schema types
    /// `utterances` as bare objects, which is the whole reason this is
    /// decoded defensively rather than trusted.
    @Test("A bare speaker label is qualified by its channel, however that arrives")
    func speakerLabelsGainTheirChannel() throws {
        let json = Data("""
        {
          "id": "tr_1",
          "status": "completed",
          "utterances": [
            {"speaker": "A", "channel": 1, "text": "local", "start": 0, "end": 900},
            {"speaker": "B", "channel": "2", "text": "remote", "start": 900, "end": 1800},
            {"speaker": "2A", "channel": 2, "text": "already qualified", "start": 1800, "end": 2700},
            {"text": "nobody in particular", "start": 2700, "end": 3600}
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(
            WhisperAIEngine.TranscriptResponse.self, from: json)
        let utterances = try #require(decoded.utterances)

        #expect(utterances.map(\.channelQualifiedSpeaker) == ["1A", "2B", "2A", nil])
        // And the labels above are the ones Amanu's own vocabulary understands.
        #expect(MultichannelSpeakerLabels.map(utterances.map {
            TranscriptSegment(
                start: TimeInterval($0.start) / 1000,
                end: TimeInterval($0.end) / 1000,
                text: $0.text,
                speaker: $0.channelQualifiedSpeaker)
        }).map(\.speaker) == ["me A", "them B", "them A", "speaker"])
    }

    /// A recording over the 5GB upload cap is over it tomorrow too, and the
    /// transcription queue retries a temporary failure at every launch.
    @Test("A file too large is permanent; the rest of the HTTP errors are not")
    func oversizeUploadsAreNotRetried() {
        #expect(WhisperAIEngine.EngineError.http("upload", 413, "").isPermanent)
        #expect(!WhisperAIEngine.EngineError.http("upload", 500, "").isPermanent)
        // 402 is the month's quota, which next month's quota fixes.
        #expect(!WhisperAIEngine.EngineError.http("submit", 402, "").isPermanent)
        #expect(!WhisperAIEngine.EngineError.timedOut.isPermanent)
        #expect(!WhisperAIEngine.EngineError.noAPIKey.isPermanent)
    }

    @Test("A verdict about the audio itself is permanent")
    func silenceIsPermanent() {
        #expect(WhisperAIEngine.EngineError.empty.isPermanent)
        #expect(WhisperAIEngine.EngineError.transcriptFailed(
            "language_detection cannot be performed on files with no spoken audio.").isPermanent)
        #expect(!WhisperAIEngine.EngineError.transcriptFailed(
            "Transcoding failed. Please try again.").isPermanent)
    }

    @Test("An error body is reported by its message, and anything else verbatim")
    func errorBodiesAreUnwrapped() {
        #expect(WhisperAIEngine.message(
            from: Data(#"{"error": "Transcript not found"}"#.utf8)) == "Transcript not found")
        #expect(WhisperAIEngine.message(
            from: Data("<html>502 Bad Gateway</html>".utf8)) == "<html>502 Bad Gateway</html>")
    }
}
