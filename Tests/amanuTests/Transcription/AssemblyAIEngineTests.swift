import Foundation
import Testing

@testable import amanu

/// Which AssemblyAI failures are worth paying for a second time.
///
/// The queue is persistent, so a failure the engine calls temporary is
/// re-uploaded at every launch until the third attempt retires the session —
/// three uploads of the same audio to a paid API for an answer that will not
/// change.
struct AssemblyAIEngineTests {
    @Test("AssemblyAI channel labels become Amanu sides")
    func channelLabelsBecomeSides() {
        let mapped = MultichannelSpeakerLabels.map([
            TranscriptSegment(start: 0, end: 1, text: "local", speaker: "1A"),
            TranscriptSegment(start: 1, end: 2, text: "remote one", speaker: "2A"),
            TranscriptSegment(start: 2, end: 3, text: "remote two", speaker: "2B"),
            TranscriptSegment(start: 3, end: 4, text: "unknown"),
        ])

        #expect(mapped.map(\.speaker) == ["me A", "them A", "them B", "speaker"])
    }

    @Test("A side left with one voice after echo filtering loses its suffix")
    func singleVoiceSidesBecomePlain() {
        let collapsed = MultichannelSpeakerLabels.collapseSingleSides([
            .init(speaker: "them A", start_ms: 0, end_ms: 1000, text: "remote"),
            .init(speaker: "me B", start_ms: 1000, end_ms: 2000, text: "local"),
        ])
        #expect(collapsed.map(\.speaker) == ["them", "me"])
    }

    @Test("A transcription request keeps channel separation and diarization")
    func requestEnablesMultichannelSpeakerLabels() throws {
        let body = AssemblyAIEngine.requestBody(
            audioURL: "https://example.test/audio.m4a",
            expectedLanguages: ["ru", "en"],
            speechModel: "universal-3-pro")

        #expect(body["audio_url"] as? String == "https://example.test/audio.m4a")
        #expect(body["multichannel"] as? Bool == true)
        #expect(body["speaker_labels"] as? Bool == true)
        #expect(body["speech_model"] as? String == "universal-3-pro")
        let detection = try #require(body["language_detection_options"] as? [String: Any])
        #expect(detection["expected_languages"] as? [String] == ["ru", "en"])
        #expect(detection["fallback_language"] as? String == "ru")
    }

    @Test("Multichannel responses never reuse a cache made from a mono mix")
    func multichannelCacheHasItsOwnName() {
        let audio = URL(fileURLWithPath: "/tmp/meeting/multichannel.m4a")
        let cache = AssemblyAIEngine.cacheURL(for: audio)
        #expect(cache.lastPathComponent == "transcript.assemblyai.multichannel.json")
        #expect(cache.lastPathComponent != "transcript.assemblyai.json")
    }

    /// The server's verdict on a silent recording, verbatim from the call that
    /// found this: a nineteen-second join with nobody speaking.
    @Test("A server-side verdict of no speech is permanent")
    func noSpokenAudioIsPermanent() {
        let error = AssemblyAIEngine.EngineError.transcriptFailed(
            "language_detection cannot be performed on files with no spoken audio.")
        #expect(error.isPermanent)
    }

    @Test("Our own empty result is permanent too")
    func emptyIsPermanent() {
        #expect(AssemblyAIEngine.EngineError.empty.isPermanent)
    }

    /// Everything else that comes back on a failed transcript happened to the
    /// request rather than to the audio, and the audio deserves another go.
    @Test("Other failures are still worth retrying")
    func everythingElseIsTemporary() {
        #expect(!AssemblyAIEngine.EngineError.transcriptFailed(
            "Transcoding failed. Please try again.").isPermanent)
        #expect(!AssemblyAIEngine.EngineError.http("upload", 500, "").isPermanent)
        #expect(!AssemblyAIEngine.EngineError.timedOut.isPermanent)
        #expect(!AssemblyAIEngine.EngineError.noAPIKey.isPermanent)
    }
}
