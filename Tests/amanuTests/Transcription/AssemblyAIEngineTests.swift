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
