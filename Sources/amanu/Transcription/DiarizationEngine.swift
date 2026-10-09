import CoreML
import FluidAudio
import Foundation

/// A single prepared manager owns its model lease until release. The busy bit
/// is set before each await because actor methods are otherwise reentrant.
actor DiarizationEngine: LocalDiarizationRuntime {
    enum RuntimeError: Error { case busy, notPrepared, invalidTimeline }

    /// FluidAudio's manager is not Sendable and runs detached processing tasks.
    /// This wrapper owns one fully initialized manager. The actor admits only
    /// one `diarize` call and waits for it before releasing the model lease;
    /// no other code can reach the wrapped manager or call `prepareModels`.
    private final class PreparedManager: @unchecked Sendable {
        private let value: OfflineDiarizerManager

        init(models: OfflineDiarizerModels, config: OfflineDiarizerConfig) {
            let value = OfflineDiarizerManager(config: config)
            value.initialize(models: models)
            self.value = value
        }

        func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
            let result: DiarizationResult
            do {
                result = try await value.process(audio)
            } catch OfflineDiarizationError.noSpeechDetected {
                throw LocalDiarizationRuntimeError.noSpeechDetected
            }
            return try result.segments.map { segment in
                let start = segment.startTimeSeconds
                let end = segment.endTimeSeconds
                guard start.isFinite, end.isFinite, start >= 0, end > start,
                      !segment.speakerId.isEmpty else { throw RuntimeError.invalidTimeline }
                return SpeakerTurn(speakerID: segment.speakerId, start: Double(start), end: Double(end))
            }
        }
    }

    private let settings: DiarizationSettings
    private let store: DiarizationModelStore
    private var manager: PreparedManager?
    private var ownsLease = false
    private var busy = false
    private var closing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releasing = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(settings: DiarizationSettings, store: DiarizationModelStore = .shared) {
        self.settings = settings
        self.store = store
    }

    func prepare() async throws {
        guard !busy && !closing else { throw RuntimeError.busy }
        if manager != nil { return }
        busy = true
        do {
            try Task.checkCancellation()
            try await store.beginUse()
            ownsLease = true
            do {
                let models = try await store.loadModels()
                try Task.checkCancellation()
                var config = OfflineDiarizerConfig.default
                config.clustering.threshold = settings.threshold
                config.postProcessing.exclusiveSegments = false
                manager = PreparedManager(models: models, config: config)
            } catch {
                await store.endUse()
                ownsLease = false
                throw error
            }
        } catch {
            finishOperation()
            throw error
        }
        finishOperation()
    }

    func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
        guard !busy && !closing else { throw RuntimeError.busy }
        guard let manager else { throw RuntimeError.notPrepared }
        busy = true
        defer { finishOperation() }
        try Task.checkCancellation()
        let turns = try await manager.diarize(audio)
        try Task.checkCancellation()
        return turns
    }

    func release() async {
        if releasing {
            await withCheckedContinuation { waiter in releaseWaiters.append(waiter) }
            return
        }
        releasing = true
        closing = true
        if busy {
            await withCheckedContinuation { waiter in waiters.append(waiter) }
        }
        manager = nil
        if ownsLease {
            await store.endUse()
            ownsLease = false
        }
        closing = false
        releasing = false
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    private func finishOperation() {
        busy = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
