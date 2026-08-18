@preconcurrency import AVFoundation
import FluidAudio
import Foundation

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

    private enum Source: Sendable {
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

    private var loadTask: Task<Void, Never>?
    private var consumerTasks: [Task<Void, Never>] = []
    private var continuations: [AsyncStream<AudioPacket>.Continuation] = []
    private var managers: [StreamingNemotronMultilingualAsrManager] = []
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
        update: @escaping @Sendable (Snapshot) -> Void
    ) -> SessionSinks? {
        stopPipeline(releaseSharedModels: true)
        self.update = update
        startedAt = Date()
        isRecording = true
        status = enabled ? .loading : .paused
        let epoch = transcript.beginRecording(enabled: enabled)
        publish()
        guard enabled else { return nil }
        return startPipeline(language: language, epoch: epoch)
    }

    /// Returns replacement sinks when enabling and nil when disabling or when
    /// the model is unavailable. The caller detaches old sinks before awaiting
    /// this method so no audio can enter a closing epoch.
    func setEnabled(_ enabled: Bool, language: String) async -> SessionSinks? {
        guard isRecording else { return nil }
        stopPipeline(releaseSharedModels: false)
        let epoch = transcript.setEnabled(enabled)
        status = enabled ? .loading : .paused
        publish()
        guard enabled else { return nil }
        return startPipeline(language: language, epoch: epoch)
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

    private func startPipeline(language: String, epoch: Int) -> SessionSinks? {
        guard modelStore.isReady(language: language) else {
            status = .modelMissing
            publish()
            return nil
        }

        let micPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        let systemPair = AsyncStream<AudioPacket>.makeStream(
            bufferingPolicy: .bufferingOldest(48))
        continuations = [micPair.continuation, systemPair.continuation]

        let micSink = makeSink(continuation: micPair.continuation, epoch: epoch)
        let systemSink = makeSink(continuation: systemPair.continuation, epoch: epoch)
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadAndConsume(
                mic: micPair.stream,
                system: systemPair.stream,
                language: language,
                epoch: epoch
            )
        }
        return SessionSinks(mic: micSink, system: systemSink)
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

            managers = [micManager, systemManager]
            status = .live
            publish()
            consumerTasks = [
                consume(mic, with: micManager, epoch: epoch),
                consume(system, with: systemManager, epoch: epoch),
            ]
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
        await manager.setPartialCallback { [weak self] text in
            Task { await self?.received(text, from: source, epoch: epoch) }
        }
    }

    nonisolated private func consume(
        _ stream: AsyncStream<AudioPacket>,
        with manager: StreamingNemotronMultilingualAsrManager,
        epoch: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await packet in stream {
                    guard !Task.isCancelled else { return }
                    _ = try await manager.process(audioBuffer: packet.buffer)
                }
            } catch is CancellationError {
                return
            } catch {
                await self?.fail(error.localizedDescription, epoch: epoch)
            }
        }
    }

    private func received(_ text: String, from source: Source, epoch: Int) {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        transcript.applyPartial(
            speaker: source.speaker,
            text: text,
            startMilliseconds: milliseconds,
            epoch: epoch
        )
        publish()
    }

    private func pipelineOverloaded(epoch: Int) {
        guard transcript.epoch == epoch else { return }
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
        let oldManagers = managers
        managers.removeAll(keepingCapacity: false)
        return (oldLoad, oldManagers)
    }

    private func publish() {
        update?(snapshot)
    }
}
