import AVFoundation
import Foundation
import Testing

@testable import amanu

/// The bookkeeping around a mid-session capture restart. The capture itself
/// needs a real device and a real route change, so what is covered here is the
/// arithmetic that decides where the audio after a restart lands on the wall
/// clock, and the record left behind for the person reading meta.json a day
/// later.
struct MicRestartTests {
    @Test func aGapWorthPaddingBecomesFrames() {
        #expect(MicRecorder.silenceFrames(gap: 0.5, sampleRate: 48000) == 24000)
        #expect(MicRecorder.silenceFrames(gap: 1.72, sampleRate: 16000) == 27520)
    }

    /// The threshold is what keeps ordinary buffer jitter from being written
    /// into the track as silence, one restart at a time.
    @Test func aGapTooShortToBeRealIsIgnored() {
        #expect(MicRecorder.silenceFrames(gap: 0.05, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: 0, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: -0.3, sampleRate: 48000) == 0)
    }

    @Test func aRestartRecordsBothSidesOfTheRouteChange() {
        let iso = ISO8601DateFormatter()
        let at = Date(timeIntervalSince1970: 1_755_710_180)
        var restart = MicRecorder.Restart(
            at: at,
            voiceProcessing: true,
            inputWas: "AirPods Pro", inputNow: "MacBook Pro Microphone",
            outputWas: "AirPods Pro", outputNow: "MacBook Pro Speakers"
        )
        restart.gapMs = 470

        let meta = restart.meta(iso: iso)
        #expect(meta["at"] as? String == iso.string(from: at))
        #expect(meta["gap_ms"] as? Int == 470)
        #expect(meta["voice_processing"] as? Bool == true)
        #expect(meta["input_was"] as? String == "AirPods Pro")
        #expect(meta["input_now"] as? String == "MacBook Pro Microphone")
        #expect(meta["output_was"] as? String == "AirPods Pro")
        #expect(meta["output_now"] as? String == "MacBook Pro Speakers")
    }

    /// A restart whose gap is still open, or that happened where no device
    /// would name itself, says less rather than saying nothing — and never
    /// puts nulls in meta.json.
    @Test func unknownFieldsAreLeftOutRatherThanWrittenNull() throws {
        let restart = MicRecorder.Restart(at: Date())
        let meta = restart.meta(iso: ISO8601DateFormatter())
        #expect(meta.count == 1)
        #expect(meta["at"] != nil)
        #expect(JSONSerialization.isValidJSONObject(meta))
    }
}
