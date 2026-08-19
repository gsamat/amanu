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

        let attached = OSAllocatedUnfairLock<Bool>(initialState: false)
        await coordinator.beginRecording(
            enabled: true,
            language: "ru-RU",
            update: { _ in },
            attach: { sinks in attached.withLock { $0 = $0 || sinks != nil } })
        let snapshot = await coordinator.snapshot

        #expect(attached.withLock { $0 } == false)
        #expect(snapshot.isEnabled)
        #expect(snapshot.status == .modelMissing)
        #expect(snapshot.entries.isEmpty)
    }

    @Test("The transcript folds away when the meeting ends, and a link brings it back")
    func transcriptVisibilityAcrossTheEndOfAMeeting() {
        func snapshot(
            recording: Bool,
            status: LiveTranscriptionCoordinator.Status,
            text: Bool
        ) -> LiveTranscriptionCoordinator.Snapshot {
            var state = LiveTranscriptState()
            state.beginRecording(enabled: true)
            if text {
                state.applyPartial(
                    speaker: .you, text: "so we agreed", startMilliseconds: 0,
                    epoch: state.epoch)
            }
            return LiveTranscriptionCoordinator.Snapshot(
                isRecording: recording, isEnabled: true, entries: state.entries,
                status: status)
        }

        // Nothing said yet, but the model is loading: the box is there so the
        // first words do not push the window taller under the reader's hands.
        #expect(StatusWindow.liveTextVisibility(
            for: snapshot(recording: true, status: .loading, text: false),
            revealed: false
        ) == .init(showsTranscript: true, showsRevealLink: false))

        #expect(StatusWindow.liveTextVisibility(
            for: snapshot(recording: true, status: .live, text: true),
            revealed: false
        ) == .init(showsTranscript: true, showsRevealLink: false))

        // The meeting is over: the box goes, the link stays.
        #expect(StatusWindow.liveTextVisibility(
            for: snapshot(recording: false, status: .idle, text: true),
            revealed: false
        ) == .init(showsTranscript: false, showsRevealLink: true))

        #expect(StatusWindow.liveTextVisibility(
            for: snapshot(recording: false, status: .idle, text: true),
            revealed: true
        ) == .init(showsTranscript: true, showsRevealLink: true))

        // A recording that produced no live text at all offers nothing to
        // reveal, so the section stays a single row.
        #expect(StatusWindow.liveTextVisibility(
            for: snapshot(recording: false, status: .idle, text: false),
            revealed: true
        ) == .init(showsTranscript: false, showsRevealLink: false))
    }

    @Test("The downloaded model runs both shared live streams end to end")
    func downloadedModelDualStreamIntegration() async throws {
        guard ProcessInfo.processInfo.environment["AMANU_RUN_LIVE_MODEL_TEST"] == "1" else {
            return
        }
        let audioPath = try #require(
            ProcessInfo.processInfo.environment["AMANU_LIVE_TEST_AUDIO"])
        let store = LiveTranscriptionModelStore()
        #expect(store.isReady(language: "ru-RU"))

        let updates = OSAllocatedUnfairLock<LiveTranscriptionCoordinator.Snapshot?>(
            initialState: nil)
        let attached = OSAllocatedUnfairLock<LiveTranscriptionCoordinator.SessionSinks?>(
            initialState: nil)
        let coordinator = LiveTranscriptionCoordinator(modelStore: store)
        await coordinator.beginRecording(
            enabled: true,
            language: "ru-RU",
            update: { snapshot in updates.withLock { $0 = snapshot } },
            attach: { sinks in attached.withLock { $0 = sinks } })

        // The sinks are handed over only once the model is loaded and its
        // consumers are running — the recorders must never feed a queue that
        // nobody is reading yet.
        for _ in 0..<600 where attached.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let sinks = try #require(attached.withLock { $0 })

        func readFixture() throws -> AVAudioPCMBuffer {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let frames = AVAudioFrameCount(file.length)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frames))
            try file.read(into: buffer)
            return buffer
        }
        sinks.mic(try readFixture())
        sinks.system(try readFixture())

        // A cold CoreML preload can take 10–15 seconds even though inference
        // itself is much faster than realtime. The recorders queue audio while
        // that happens, so the integration test must wait for load + decode.
        for _ in 0..<600 {
            let speakers = updates.withLock { snapshot in
                Set((snapshot?.entries ?? []).compactMap { entry in
                    if case .speech(let block) = entry { return block.speaker }
                    return nil
                })
            }
            if speakers == [.you, .them] { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let snapshot = try #require(updates.withLock { $0 })
        let blocks = snapshot.entries.compactMap { entry -> LiveTranscriptState.Block? in
            if case .speech(let block) = entry { return block }
            return nil
        }
        #expect(Set(blocks.map(\.speaker)) == [.you, .them])
        #expect(blocks.allSatisfy { !$0.text.isEmpty })
        await coordinator.finishRecording()
    }
}
