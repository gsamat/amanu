import AVFoundation
import Foundation
import Testing

@testable import amanu

/// AVFAudio reports misuse by raising an Objective-C exception, which Swift
/// cannot catch: it unwinds the stack and, on the main run loop, kills the
/// timer that fires auto-record. `MicRecorder.guarded` must turn it into a throw.
struct MicExceptionGuardTests {
    @Test("An Objective-C exception becomes a thrown error that keeps its reason")
    func exceptionBecomesError() {
        do {
            try MicRecorder.guarded {
                NSException(name: .genericException, reason: "tap busy", userInfo: nil).raise()
            }
            Issue.record("the exception was not turned into an error")
        } catch {
            #expect(error.localizedDescription.contains("tap busy"))
        }
    }

    @Test("A body that does not raise runs untouched")
    func plainBodyRuns() throws {
        var ran = false
        try MicRecorder.guarded { ran = true }
        #expect(ran)
    }

    // The two below raise the real AVFAudio exceptions, so they need an input
    // device; without one they are cancelled (shown as skipped) rather than passed.
    // The engine is returned with its node: the node does not keep it alive.
    private static func inputNode() throws -> (engine: AVAudioEngine, input: AVAudioInputNode) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if input.outputFormat(forBus: 0).sampleRate <= 0 {
            try Test.cancel("no audio input device on this machine")
        }
        return (engine, input)
    }

    @Test("A second installTap on the same bus becomes a thrown error")
    func doubleTapThrows() throws {
        let (engine, input) = try Self.inputNode()
        defer { withExtendedLifetime(engine) {} }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        defer { input.removeTap(onBus: 0) }

        #expect(throws: (any Error).self) {
            try MicRecorder.guarded {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
            }
        }
    }

    @Test("A tap format that does not match the input becomes a thrown error")
    func badFormatThrows() throws {
        let (engine, input) = try Self.inputNode()
        defer { withExtendedLifetime(engine) {} }
        let hardware = input.outputFormat(forBus: 0)
        let wrong = try #require(
            AVAudioFormat(
                standardFormatWithSampleRate: hardware.sampleRate == 16_000 ? 44_100 : 16_000,
                channels: 1))
        #expect(throws: (any Error).self) {
            try MicRecorder.guarded {
                input.installTap(onBus: 0, bufferSize: 4096, format: wrong) { _, _ in }
            }
        }
        input.removeTap(onBus: 0)
    }
}
