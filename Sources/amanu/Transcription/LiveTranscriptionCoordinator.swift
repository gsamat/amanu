@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.lock

/// Runs the optional low-latency transcript beside the durable recorder. The
/// two speakers get independent streaming state while sharing the heavyweight
/// CoreML model bundle.
actor LiveTranscriptionCoordinator {
    private struct AudioPacket: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer
    }

    enum Status: Sendable, Equatable {
        case idle
        case paused
        case loading
        case live
        case modelMissing
        case overloaded
        case error(String)
    }

    struct Snapshot: Sendable {
        let isRecording: Bool
        let isEnabled: Bool
        let entries: [LiveTranscriptState.Entry]
        let status: Status
    }

    struct SessionSinks: Sendable {
        let mic: LiveAudioBufferRelay.Sink
        let system: LiveAudioBufferRelay.Sink
    }

    private enum Source: Sendable, Hashable {
        case mic
        case system

        var speaker: LiveTranscriptState.Speaker {
            self == .mic ? .you : .them
        }
    }

    private let modelStore: LiveTranscriptionModelStore
    private var transcript = LiveTranscriptState()
    private var status: Status = .idle
    private var isRecording = false
    private var startedAt = Date()
    private var update: (@Sendable (Snapshot) -> Void)?
    /// Handing the recorders their sinks is deferred until the model is
    /// actually consuming audio — see `startPipeline`.
    private var attach: (@Sendable (SessionSinks?) -> Void)?
    private var pendingSinks: SessionSinks?
    private var drops: [Date] = []
    /// The engine reports one running transcript per speaker and never says
    /// where an utterance ended, so the pause is what ends it here.
    private var partials = CumulativePartials()
    private var silentSeconds: [Source: Double] = [:]
    /// Set by the engine's callback the moment it decodes something, and read
    /// by the consumer that fed it. Both run outside this actor, and a hop
    /// through it would arrive after the audio it belongs to had been counted.
    private var decodedSomething: [Source: OSAllocatedUnfairLock<Bool>] = [:]

    private var loadTask: Task<Void, Never>?
    private var consumerTasks: [Task<Void, Never>] = []
    private var continuations: [AsyncStream<AudioPacket>.Continuation] = []
    private var managers: [Source: StreamingNemotronMultilingualAsrManager] = [:]
    private var sharedModels: SharedNemotronMultilingualModels?

    init(modelStore: LiveTranscriptionModelStore = .init()) {
        self.modelStore = modelStore
    }

    var snapshot: Snapshot {
        Snapshot(
            isRecording: isRecording,
            isEnabled: transcript.isEnabled,
            entries: transcript.entries,
            status: status
        )
    }

    func beginRecording(
        enabled: Bool,
        language: String,
        update: @escaping @Sendable (Snapshot) -> Void,
        attach: @escaping @Sendable (SessionSinks?) -> Void
    ) {
        stopPipeline(releaseSharedModels: true)
        self.update = update
        self.attach = attach
        startedAt = Date()
        isRecording = true
        status = enabled ? .loading : .paused
        let epoch = transcript.beginRecording(enabled: enabled)
        publish()
        guard enabled else { return }
        startPipeline(language: language, epoch: epoch)
    }

    /// The caller detaches the old sinks before calling this, so no audio can
    /// enter a closing epoch; new sinks arrive through `attach` once the model
    /// is loaded and consuming.
    func setEnabled(_ enabled: Bool, language: String) {
        guard isRecording else { return }
        stopPipeline(releaseSharedModels: false)
        let epoch = transcript.setEnabled(enabled)
        status = enabled ? .loading : .paused
        publish()
        guard enabled else { return }
        startPipeline(language: language, epoch: epoch)
    }

    func finishRecording() async {
        transcript.finishRecording()
        isRecording = false
        status = .idle
        publish()

        // In contrast to a temporary toggle, meeting stop is a hard memory
        // boundary: wait for an in-progress preload and both managers to let
        // go before the canonical Parakeet job is allowed to start.
        let detached = detachPipeline()
        await detached.load?.value
        for manager in detached.managers { await manager.cleanup() }
        sharedModels = nil
    }

    /// Builds the queues and their sinks but does not hand the sinks over.
    ///
    /// Loading Nemotron takes several seconds, and audio pushed into a queue
    /// nobody is reading yet fills five seconds of buffer and then overflows —
    /// which used to be reported as "your Mac couldn't keep up" before a
    /// single word had been transcribed. The recorders start feeding the
    /// queues at the moment the model starts consuming them, and not before.
    private func startPipeline(language: String, epoch: Int) {
        guard modelStore.isReady(language: language) else {
            status = .modelMissing
            publish()
            return
        }
        drops.removeAll(keepingCapacity: true)
        partials.reset()
        silentSeconds.removeAll(keepingCapacity: true)
        decodedSomething = [
            .mic: .init(initialState: false),
            .system: .init(initialState: false),
        ]

        let micPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        let systemPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        continuations = [micPair.continuation, systemPair.continuation]

        pendingSinks = SessionSinks(
            mic: makeSink(continuation: micPair.continuation, epoch: epoch),
            system: makeSink(continuation: systemPair.continuation, epoch: epoch))
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadAndConsume(
                mic: micPair.stream,
                system: systemPair.stream,
                language: language,
                epoch: epoch
            )
        }
    }

    nonisolated private func makeSink(
        continuation: AsyncStream<AudioPacket>.Continuation,
        epoch: Int
    ) -> LiveAudioBufferRelay.Sink {
        { [weak self] buffer in
            switch continuation.yield(AudioPacket(buffer: buffer)) {
            case .enqueued:
                break
            case .dropped:
                Task { await self?.pipelineOverloaded(epoch: epoch) }
            case .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    private func loadAndConsume(
        mic: AsyncStream<AudioPacket>,
        system: AsyncStream<AudioPacket>,
        language: String,
        epoch: Int
    ) async {
        do {
            let shared: SharedNemotronMultilingualModels
            if let sharedModels {
                shared = sharedModels
            } else {
                shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(
                    from: modelStore.variantDirectory(language: language))
            }
            guard transcript.epoch == epoch, transcript.isEnabled else { return }
            sharedModels = shared

            let micManager = StreamingNemotronMultilingualAsrManager()
            let systemManager = StreamingNemotronMultilingualAsrManager()
            try await micManager.loadFromShared(shared)
            try await systemManager.loadFromShared(shared)
            await micManager.setLanguage(language)
            await systemManager.setLanguage(language)
            await installCallback(on: micManager, source: .mic, epoch: epoch)
            await installCallback(on: systemManager, source: .system, epoch: epoch)
            guard transcript.epoch == epoch, transcript.isEnabled else {
                await micManager.cleanup()
                await systemManager.cleanup()
                return
            }

            managers = [.mic: micManager, .system: systemManager]
            consumerTasks = [
                consume(
                    mic, from: .mic, with: micManager,
                    spoken: decodedSomething[.mic], epoch: epoch),
                consume(
                    system, from: .system, with: systemManager,
                    spoken: decodedSomething[.system], epoch: epoch),
            ]
            status = .live
            publish()
            if let sinks = pendingSinks {
                pendingSinks = nil
                attach?(sinks)
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error.localizedDescription, epoch: epoch)
        }
    }

    private func installCallback(
        on manager: StreamingNemotronMultilingualAsrManager,
        source: Source,
        epoch: Int
    ) async {
        let pulse = decodedSomething[source]
        await manager.setPartialCallback { [weak self] text in
            pulse?.withLock { $0 = true }
            Task { await self?.received(text, from: source, epoch: epoch) }
        }
    }

    nonisolated private func consume(
        _ stream: AsyncStream<AudioPacket>,
        from source: Source,
        with manager: StreamingNemotronMultilingualAsrManager,
        spoken pulse: OSAllocatedUnfairLock<Bool>?,
        epoch: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await packet in stream {
                    guard !Task.isCancelled else { return }
                    let seconds = Double(packet.buffer.frameLength)
                        / packet.buffer.format.sampleRate
                    _ = try await manager.process(audioBuffer: packet.buffer)
                    let spoken = pulse?.withLock { decoded -> Bool in
                        defer { decoded = false }
                        return decoded
                    } ?? false
                    await self?.decoded(
                        seconds: seconds, spoken: spoken, from: source, epoch: epoch)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.fail(error.localizedDescription, epoch: epoch)
            }
        }
    }

    private func received(_ text: String, from source: Source, epoch: Int) {
        guard transcript.epoch == epoch else { return }
        guard let text = partials.text(from: text, for: source.speaker) else { return }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        transcript.applyPartial(
            speaker: source.speaker,
            text: text,
            startMilliseconds: milliseconds,
            epoch: epoch
        )
        publish()
    }

    /// How much audio a side has to go through without decoding a word before
    /// its block is closed. Tokens only arrive while someone is speaking, so a
    /// gap in them is a pause — the audio needs no second listen to hear it.
    ///
    /// Measured in audio rather than on the clock: the model can fall a couple
    /// of seconds behind while it warms up, and a stopwatch reads that as a
    /// pause and cuts the sentence it is still working through.
    private static let pauseEndingABlock: Double = 2

    private func decoded(
        seconds: Double, spoken: Bool, from source: Source, epoch: Int
    ) async {
        guard transcript.epoch == epoch else { return }
        guard !spoken else {
            silentSeconds[source] = 0
            return
        }
        let silence = (silentSeconds[source] ?? 0) + seconds
        silentSeconds[source] = silence
        guard silence >= Self.pauseEndingABlock else { return }
        await endSegment(on: source, epoch: epoch)
    }

    /// Closes the block and asks the engine to commit, which clears the
    /// accumulation the next block would otherwise be appended to — the whole
    /// meeting decoded again on every chunk, into one paragraph per speaker.
    private func endSegment(on source: Source, epoch: Int) async {
        guard transcript.endSegment(speaker: source.speaker, epoch: epoch) else { return }
        partials.close(source.speaker)
        publish()
        _ = try? await managers[source]?.finish()
    }

    /// A dropped buffer here and there is what a bounded queue is for. Live
    /// text is a preview, and losing a fifth of a second of it is not worth
    /// tearing the pipeline down — falling steadily behind is.
    private static let dropWindow: TimeInterval = 5
    private static let dropsBeforeGivingUp = 20

    private func pipelineOverloaded(epoch: Int) {
        guard transcript.epoch == epoch else { return }
        let now = Date()
        drops.append(now)
        drops.removeAll { now.timeIntervalSince($0) > Self.dropWindow }
        guard drops.count >= Self.dropsBeforeGivingUp else { return }

        stopPipeline(releaseSharedModels: false)
        transcript.invalidateActiveEpoch()
        status = .overloaded
        publish()
    }

    private func fail(_ message: String, epoch: Int) {
        guard transcript.epoch == epoch else { return }
        stopPipeline(releaseSharedModels: false)
        transcript.invalidateActiveEpoch()
        status = .error(message)
        publish()
    }

    /// Synchronous cancellation keeps toggle/stop deterministic. Manager
    /// cleanup is scheduled separately; shared models are retained across a
    /// temporary disable and released at the end of the recording.
    private func stopPipeline(releaseSharedModels: Bool) {
        pendingSinks = nil
        attach?(nil)
        let detached = detachPipeline()
        let oldManagers = detached.managers
        if !oldManagers.isEmpty {
            Task {
                for manager in oldManagers { await manager.cleanup() }
            }
        }
        if releaseSharedModels { sharedModels = nil }
    }

    private func detachPipeline() -> (
        load: Task<Void, Never>?, managers: [StreamingNemotronMultilingualAsrManager]
    ) {
        let oldLoad = loadTask
        oldLoad?.cancel()
        loadTask = nil
        continuations.forEach { $0.finish() }
        continuations.removeAll(keepingCapacity: false)
        consumerTasks.forEach { $0.cancel() }
        consumerTasks.removeAll(keepingCapacity: false)
        let oldManagers = Array(managers.values)
        managers.removeAll(keepingCapacity: false)
        return (oldLoad, oldManagers)
    }

    private func publish() {
        update?(snapshot)
    }
}
