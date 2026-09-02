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

    @Test("A pause closes the block and the next words open another")
    func pauseEndsABlock() {
        var state = LiveTranscriptState()
        let epoch = state.beginRecording(enabled: true)

        state.applyPartial(
            speaker: .you, text: "Привет", startMilliseconds: 100, epoch: epoch)
        let closed = state.endSegment(speaker: .you, epoch: epoch)
        #expect(closed)
        state.applyPartial(
            speaker: .you, text: "Как дела", startMilliseconds: 9_000, epoch: epoch)

        #expect(state.entries == [
            .speech(.init(
                speaker: .you,
                text: "Привет",
                startMilliseconds: 100,
                isProvisional: false
            )),
            .speech(.init(
                speaker: .you,
                text: "Как дела",
                startMilliseconds: 9_000,
                isProvisional: true
            )),
        ])
    }

    @Test("Closing twice, or in a stale epoch, closes nothing")
    func endSegmentIsIdempotent() {
        var state = LiveTranscriptState()
        let epoch = state.beginRecording(enabled: true)
        state.applyPartial(
            speaker: .them, text: "Слово", startMilliseconds: 10, epoch: epoch)

        let closed = state.endSegment(speaker: .them, epoch: epoch)
        let again = state.endSegment(speaker: .them, epoch: epoch)
        let otherSide = state.endSegment(speaker: .you, epoch: epoch)
        let stale = state.endSegment(speaker: .them, epoch: epoch - 1)
        #expect(closed)
        #expect(!again)
        #expect(!otherSide)
        #expect(!stale)
        #expect(state.entries.count == 1)
    }

    @Test("The running transcript is split at the block already on screen")
    func cumulativePartialsSplit() {
        var partials = CumulativePartials()

        let first = partials.text(from: "Привет", for: .you)
        let revised = partials.text(from: "Привет, мир", for: .you)
        partials.close(.you)

        // Still decoded before the engine was asked to commit: the closed text
        // comes back, sometimes with the full stop that ended it.
        let stale = partials.text(from: "Привет, мир", for: .you)
        let staleWithStop = partials.text(from: "Привет, мир.", for: .you)
        let carriedOver = partials.text(from: "Привет, мир. Как дела", for: .you)
        // And once the engine has cleared its own accumulation, the report is
        // the new block from the first word — never from the full stop that
        // ended the block before it.
        let afterCommit = partials.text(from: ". Как дела, друг", for: .you)
        let nothingButAStop = partials.text(from: ".", for: .them)
        // The other side keeps its own reckoning.
        let otherSide = partials.text(from: "Привет, мир", for: .them)

        #expect(first == "Привет")
        #expect(revised == "Привет, мир")
        #expect(stale == nil)
        #expect(staleWithStop == nil)
        #expect(carriedOver == "Как дела")
        #expect(afterCommit == "Как дела, друг")
        #expect(nothingButAStop == nil)
        #expect(otherSide == "Привет, мир")
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

    @Test("Ending the recording releases everything the closures captured")
    func finishRecordingReleasesTheCapturedSession() async {
        // AppController's closures capture the recording session. The live
        // coordinator outlives it, so retaining either closure retains the
        // mic engine and an explicitly enabled voice route after Stop.
        final class Token: Sendable {}
        let coordinator = LiveTranscriptionCoordinator(
            modelStore: LiveTranscriptionModelStore(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("amanu-live-release-\(UUID().uuidString)")))

        weak var captured: Token?
        do {
            let token = Token()
            captured = token
            await coordinator.beginRecording(
                enabled: false,
                language: "ru-RU",
                update: { _ in _ = token },
                attach: { _ in _ = token })
        }
        #expect(captured != nil)

        await coordinator.finishRecording()
        #expect(captured == nil)
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

        func readFixture(_ path: String) throws -> AVAudioPCMBuffer {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let frames = AVAudioFrameCount(file.length)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frames))
            try file.read(into: buffer)
            return buffer
        }
        // The recorders hand over what their taps give them, a fraction of a
        // second at a time, and the pause between blocks is measured in the
        // audio that goes by: feeding whole files in one buffer would be a
        // different pipeline from the one being tested.
        // Twice realtime rather than all at once: the queue between the sinks
        // and the model holds a few seconds, and a test that fills it in one go
        // is testing the overload path instead.
        func feed(_ buffer: AVAudioPCMBuffer, to sink: LiveAudioBufferRelay.Sink) async throws {
            let slice = AVAudioFrameCount(buffer.format.sampleRate / 10)
            var offset = AVAudioFrameCount(0)
            while offset < buffer.frameLength {
                let frames = min(slice, buffer.frameLength - offset)
                let piece = try #require(
                    AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames))
                piece.frameLength = frames
                for channel in 0..<Int(buffer.format.channelCount) {
                    guard let source = buffer.floatChannelData?[channel],
                          let destination = piece.floatChannelData?[channel]
                    else { continue }
                    destination.update(from: source + Int(offset), count: Int(frames))
                }
                sink(piece)
                offset += frames
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await feed(try readFixture(audioPath), to: sinks.mic)
        try await feed(try readFixture(audioPath), to: sinks.system)

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

        // Three seconds of silence, then more speech. The engine goes on
        // reporting the whole session's transcript, so what is checked here is
        // that the pause was noticed on both sides and the words after it
        // opened blocks of their own instead of growing the first two.
        let secondPath = ProcessInfo.processInfo.environment["AMANU_LIVE_TEST_AUDIO_2"]
            ?? audioPath
        func silence(like example: AVAudioPCMBuffer, seconds: Double) throws
            -> AVAudioPCMBuffer
        {
            let frames = AVAudioFrameCount(example.format.sampleRate * seconds)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: example.format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<Int(buffer.format.channelCount) {
                buffer.floatChannelData?[channel].update(
                    repeating: 0, count: Int(frames))
            }
            return buffer
        }
        let quiet = try silence(like: try readFixture(audioPath), seconds: 3)
        try await feed(quiet, to: sinks.mic)
        try await feed(quiet, to: sinks.system)
        try await feed(try readFixture(secondPath), to: sinks.mic)
        try await feed(try readFixture(secondPath), to: sinks.system)

        for _ in 0..<600 {
            let counts = blocksBySpeaker(updates).mapValues(\.count)
            if (counts[.you] ?? 0) >= 2, (counts[.them] ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let split = blocksBySpeaker(updates)
        #expect((split[.you]?.count ?? 0) >= 2)
        #expect((split[.them]?.count ?? 0) >= 2)
        for blocks in split.values {
            // The block the pause closed keeps its own words: the report the
            // engine repeats must not come back as the opening of the next.
            #expect(blocks.dropLast().allSatisfy { !$0.isProvisional })
            for (earlier, later) in zip(blocks, blocks.dropFirst()) {
                #expect(!later.text.hasPrefix(earlier.text))
            }
        }
        await coordinator.finishRecording()
    }

    private func blocksBySpeaker(
        _ updates: OSAllocatedUnfairLock<LiveTranscriptionCoordinator.Snapshot?>
    ) -> [LiveTranscriptState.Speaker: [LiveTranscriptState.Block]] {
        let entries = updates.withLock { $0?.entries } ?? []
        return Dictionary(grouping: entries.compactMap { entry in
            if case .speech(let block) = entry { return block }
            return nil
        }, by: \.speaker)
    }
}
