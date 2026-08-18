@preconcurrency import AVFoundation
import Foundation
import os.lock
import Testing

@testable import amanu

struct LiveTranscriptTests {
    @Test("Live transcription is opt-in")
    func configDefaultsOff() {
        #expect(!Config.liveTranscriptionEnabled(in: nil))
        #expect(!Config.liveTranscriptionEnabled(in: [:]))
        #expect(Config.liveTranscriptionEnabled(in: [
            "live_transcription": ["enabled": true]
        ]))
    }

    @Test("A two-letter Russian setting selects Nemotron's Russian prompt")
    func russianPrompt() {
        #expect(LiveTranscriptionLanguage.prompt(for: "ru") == "ru-RU")
        #expect(LiveTranscriptionLanguage.prompt(for: "ru-RU") == "ru-RU")
        #expect(LiveTranscriptionLanguage.prompt(for: nil) == "auto")
        #expect(LiveTranscriptionLanguage.prompt(for: "unknown") == "auto")
    }

    @Test("A cumulative partial revises one block instead of duplicating it")
    func partialRevision() {
        var state = LiveTranscriptState()
        let epoch = state.beginRecording(enabled: true)

        state.applyPartial(
            speaker: .you, text: "Привет", startMilliseconds: 100, epoch: epoch)
        state.applyPartial(
            speaker: .you, text: "Привет, мир", startMilliseconds: 100, epoch: epoch)

        #expect(state.entries == [
            .speech(.init(
                speaker: .you,
                text: "Привет, мир",
                startMilliseconds: 100,
                isProvisional: true
            ))
        ])
    }

    @Test("Disabling freezes text and re-enabling starts a marked epoch")
    func disableAndResume() {
        var state = LiveTranscriptState()
        let first = state.beginRecording(enabled: true)
        state.applyPartial(
            speaker: .them, text: "До паузы", startMilliseconds: 500, epoch: first)

        _ = state.setEnabled(false)
        let second = state.setEnabled(true)
        state.applyPartial(
            speaker: .them, text: "После паузы", startMilliseconds: 4_000, epoch: second)

        #expect(state.entries == [
            .speech(.init(
                speaker: .them,
                text: "До паузы",
                startMilliseconds: 500,
                isProvisional: false
            )),
            .resumed,
            .speech(.init(
                speaker: .them,
                text: "После паузы",
                startMilliseconds: 4_000,
                isProvisional: true
            )),
        ])
    }

    @Test("A late result from a disabled epoch is ignored")
    func staleResult() {
        var state = LiveTranscriptState()
        let stale = state.beginRecording(enabled: true)
        _ = state.setEnabled(false)
        let current = state.setEnabled(true)

        state.applyPartial(
            speaker: .you, text: "Старое", startMilliseconds: 100, epoch: stale)
        state.applyPartial(
            speaker: .you, text: "Новое", startMilliseconds: 200, epoch: current)

        #expect(state.entries == [
            .speech(.init(
                speaker: .you,
                text: "Новое",
                startMilliseconds: 200,
                isProvisional: true
            ))
        ])
    }

    @Test("A failed live pipeline invalidates callbacks without changing the saved choice")
    func failedPipelineEpoch() {
        var state = LiveTranscriptState()
        let failed = state.beginRecording(enabled: true)
        state.applyPartial(
            speaker: .you, text: "Before failure", startMilliseconds: 10, epoch: failed)

        state.invalidateActiveEpoch()
        state.applyPartial(
            speaker: .you, text: "Late callback", startMilliseconds: 20, epoch: failed)

        #expect(state.isEnabled)
        #expect(state.entries == [
            .speech(.init(
                speaker: .you,
                text: "Before failure",
                startMilliseconds: 10,
                isProvisional: false
            ))
        ])
    }

    @Test("The recorder relay owns its buffer and closes during recording pause")
    func audioRelayCopyAndGate() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        source.frameLength = 2
        source.floatChannelData![0][0] = 0.25
        source.floatChannelData![0][1] = -0.5

        let received = OSAllocatedUnfairLock(initialState: [[Float]]())
        let relay = LiveAudioBufferRelay()
        relay.install { buffer in
            received.withLock { values in
                values.append(Array(UnsafeBufferPointer(
                    start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            }
        }

        #expect(relay.forward(source))
        source.floatChannelData![0][0] = 1
        #expect(received.withLock { $0 } == [[0.25, -0.5]])

        relay.isPaused = true
        #expect(!relay.forward(source))
        #expect(received.withLock { $0.count } == 1)

        relay.isPaused = false
        #expect(relay.forward(source))
        #expect(received.withLock { $0.count } == 2)

        relay.install(nil)
        #expect(!relay.forward(source))
    }

    @Test("The live model store detects complete language variants")
    func modelStoreReadiness() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-live-model-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LiveTranscriptionModelStore(root: root)

        #expect(store.variantDirectory(language: "en-US").path.hasSuffix("latin/1120ms"))
        #expect(store.variantDirectory(language: "ru-RU").path.hasSuffix("multilingual/1120ms"))
        #expect(!store.isReady(language: "ru-RU"))

        let variant = store.variantDirectory(language: "ru-RU")
        try FileManager.default.createDirectory(
            at: variant.appendingPathComponent("encoder.mlmodelc"),
            withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: variant.appendingPathComponent("metadata.json"))
        try Data("{}".utf8).write(to: variant.appendingPathComponent("tokenizer.json"))
        try FileManager.default.createDirectory(
            at: variant.appendingPathComponent("decoder_joint.mlmodelc"),
            withIntermediateDirectories: true)

        #expect(store.isReady(language: "ru-RU"))
    }

    @Test("Enabling without a downloaded model fails safely and leaves recording independent")
    func missingModelDoesNotCreateSinks() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-live-missing-\(UUID().uuidString)")
        let coordinator = LiveTranscriptionCoordinator(
            modelStore: LiveTranscriptionModelStore(root: missingRoot))

        let sinks = await coordinator.beginRecording(
            enabled: true, language: "ru-RU", update: { _ in })
        let snapshot = await coordinator.snapshot

        #expect(sinks == nil)
        #expect(snapshot.isEnabled)
        #expect(snapshot.status == .modelMissing)
        #expect(snapshot.entries.isEmpty)
    }
}
