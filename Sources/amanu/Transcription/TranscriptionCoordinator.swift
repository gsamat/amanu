import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
///
/// Per-track engines (parakeet) get mic.caf → "me" and system.caf → "them";
/// each track's segments are shifted by its start offset and merged by
/// timestamp. AssemblyAI gets aligned stereo and returns channel-qualified
/// speaker labels. Mixed engines still get one mixed.m4a and map anonymous
/// labels back onto me/them from the source tracks' energy.
///
/// Either way the result is transcript.json (canonical) plus transcript.md
/// (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
///
/// The coordinator owns the queue and the order of events. Which engine a
/// session gets is `EngineResolver`'s question, how the audio reaches it is
/// `TranscriptionInputs`', and what a failure costs the session is
/// `TranscriptionFailurePolicy`'s.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    /// Sessions a drain set aside because the machine could not transcribe
    /// them — a model that would not download, no network, no key. They go
    /// back in front of the queue the next time something is queued, rather
    /// than at once: the same drain would only fail them the same way.
    private var heldBack: [URL] = []
    private var draining = false
    private var processing = false
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []
    /// Whoever is waiting for the queue to run dry — see `waitUntilIdle`.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var environmentalFailureNoted = false
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    private let engines: EngineResolver
    /// The engine the session in hand was given, for the failure report when
    /// it throws: nil until one was prepared.
    private var current: TranscriptionEngine?
    private let onStop: @Sendable () -> String?
    private let echoCanceller: EchoCancellerFactory
    private let diarizerFactory: @Sendable (DiarizationSettings) -> any LocalDiarizationRuntime
    private let modelFingerprint: @Sendable () async throws -> String

    typealias EchoCancellerFactory = @Sendable () throws -> EchoCanceller

    /// `engine` is one settled on in advance rather than chosen for the
    /// machine at the moment there is work. Only tests pass one: everything
    /// real wants the configured answer, and wants it decided late.
    init(engine: TranscriptionEngine? = nil,
         onStop: @escaping @Sendable () -> String? = { Config.onStop() },
         echoCanceller: @escaping EchoCancellerFactory = { try EchoCanceller() },
         diarizerFactory: @escaping @Sendable (DiarizationSettings) -> any LocalDiarizationRuntime = {
             DiarizationEngine(settings: $0)
         },
         modelFingerprint: @escaping @Sendable () async throws -> String = {
             try await DiarizationModelStore.shared.fingerprint()
         }) {
        engines = EngineResolver(fixed: engine)
        self.onStop = onStop
        self.echoCanceller = echoCanceller
        self.diarizerFactory = diarizerFactory
        self.modelFingerprint = modelFingerprint
    }

    init(engines: EngineResolver,
         onStop: @escaping @Sendable () -> String? = { Config.onStop() },
         echoCanceller: @escaping EchoCancellerFactory = { try EchoCanceller() },
         diarizerFactory: @escaping @Sendable (DiarizationSettings) -> any LocalDiarizationRuntime = {
             DiarizationEngine(settings: $0)
         },
         modelFingerprint: @escaping @Sendable () async throws -> String = {
             try await DiarizationModelStore.shared.fingerprint()
         }) {
        self.engines = engines
        self.onStop = onStop
        self.echoCanceller = echoCanceller
        self.diarizerFactory = diarizerFactory
        self.modelFingerprint = modelFingerprint
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            Task {
                do { try await archiveRecordingOnly(sessionDir) }
                catch { log(sessionDir, "recording-only archive deferred: \(error)") }
            }
            return
        }
        requeueHeldBack()
        add(sessionDir)
        drainIfIdle()
    }

    private func requeueHeldBack() {
        guard !draining else { return }
        let held = heldBack
        heldBack = []
        queue = held.filter { !isQueued($0) } + queue
    }

    /// Queue a folder unless it is already queued under any spelling of its
    /// path. The importer hands over a path with its symlinks resolved and a
    /// rescan of the root does not, so under /var — which is /private/var —
    /// one session was two entries, and was transcribed and paid for twice.
    private func add(_ dir: URL) {
        guard !isQueued(dir) else { return }
        queue.append(dir)
    }

    private func isQueued(_ dir: URL) -> Bool {
        let key = Self.identity(of: dir)
        return queue.contains { Self.identity(of: $0) == key }
    }

    private static func identity(of dir: URL) -> String {
        dir.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// With no transcript the audio is the only copy of the meeting. Archive
    /// it regardless of keep_audio, under the same claim as transcription.
    func archiveRecordingOnly(_ dir: URL) async throws {
        try SessionClaim.acquire(dir, stage: .transcribe)
        await Task.detached(priority: .utility) { TrackCompressor.compress(sessionDir: dir) }.value
        StopHook.owe(dir)
        SessionClaim.release(dir)
        StopHook.fireIfOwed(dir, command: onStop())
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        // A config that cannot be read holds the queue — see `Config.Unreadable`.
        // The app offers the folder again once the file is fixed.
        guard Config.unreadableReason == nil, Config.transcriptionEnabled() else { return }
        requeueHeldBack()
        let pending = Self.pendingSessions(in: root)
        for dir in pending { add(dir) }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    /// The folders `resumePending` would take, as a plain question about a
    /// directory: which sessions have ended, have no transcript, have not been
    /// retired, and are not being worked on by somebody else. Separate from the
    /// queueing so the answer can be checked without a coordinator running a
    /// drain over real audio.
    static func pendingSessions(in root: URL) -> [URL] {
        // Through the one list of sessions, which leaves out the importer's
        // hidden staging folders: without that a half-finished import could
        // be transcribed from its staging directory, and then again once it
        // had arrived.
        let fm = FileManager.default
        return SessionInventory.sessionFolders(in: root)
            .filter {
                (!fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    || TranscriptVersions.isRequested($0)
                    || fm.fileExists(atPath: $0.appendingPathComponent(
                        TranscriptVersions.journalDirectory).path)
                    || (Config.localDiarizationEnabled()
                        && DiarizationState.read($0)?.isOutstanding == true))
                    && !TranscriptionFailurePolicy.hasGivenUp(on: $0)
                    // A session another process is already transcribing is not
                    // pending, it is in progress somewhere else. Queueing it
                    // would be refused at the claim anyway; leaving it out is
                    // what stops the menu bar counting somebody else's work as
                    // its own backlog.
                    && !SessionClaim.isHeld($0)
            }
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        environmentalFailureNoted = false
        Task { await drain() }
    }

    private func drain() async {
        await takeProcessingTurn()
        defer { releaseProcessingTurn() }
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribeAndAnnounce(dir)
            } catch let busy as SessionClaim.Busy {
                // Not a failure of this session — a collision with another
                // process that has it. Counting it would retire a perfectly
                // good recording after three unlucky launches, so the folder is
                // simply left where it is: the filesystem is the queue, and the
                // next `resumePending` offers it again once the owner is done.
                log(dir, "\(busy)")
            } catch is CancellationError {
                log(dir, "processing cancelled; the session remains resumable")
            } catch is AlreadyTranscribed {
                // Somebody finished it while it waited here — nothing to do,
                // and nothing to announce twice.
            } catch let held as Config.Unreadable {
                // Not this session's failure either, and not only this one's:
                // everything behind it would be held for the same reason. The
                // folders stay where they are and are offered again when the
                // file can be read.
                log(dir, "\(held)")
                queue.removeAll()
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                let outcome = TranscriptionFailurePolicy.record(
                    error, for: dir, engine: current, notify: !environmentalFailureNoted)
                if outcome == .environmental {
                    environmentalFailureNoted = true
                    heldBack.append(dir)
                }
            }
        }
        await releaseEngine()
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
        guard !draining else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Return once nothing is being transcribed: at once when the queue is
    /// idle, otherwise when the drain running now — and any it runs into —
    /// has finished.
    ///
    /// For the sweep, which finishes sessions left over from earlier runs.
    /// `resumePending` returns as soon as its drain has started, so a sweep
    /// run straight after it went through the recordings folder alongside
    /// the drain, reaching for the session being settled and filling its log
    /// with "another amanu has this session".
    func waitUntilIdle() async {
        guard draining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Transcribe one session now, and wait for it.
    ///
    /// `enqueue` belongs to the running app: it hands work to a queue, reports
    /// through the menu bar, and leaves a failure in transcribe.log for
    /// whoever looks. `amanu process` has a person and a terminal instead, so
    /// it wants the failure back to print and to exit on. The work is the same
    /// either way, down to pulling one channel out of `audio.m4a` — a settled
    /// session has nothing else left to transcribe from.
    func transcribeNow(_ dir: URL) async throws {
        await takeProcessingTurn()
        defer { releaseProcessingTurn() }
        do {
            try await transcribeAndAnnounce(dir)
        } catch let busy as SessionClaim.Busy {
            // The app has this session. Nothing failed, so nothing is recorded
            // against it — the person gets the sentence and the folder is left
            // exactly as the process that owns it expects to find it.
            log(dir, "\(busy)")
            await releaseEngine()
            throw busy
        } catch let held as Config.Unreadable {
            log(dir, "\(held)")
            await releaseEngine()
            throw held
        } catch is AlreadyTranscribed {
            // The transcript asked for exists: whoever wrote it did the work.
        } catch is CancellationError {
            await releaseEngine()
            throw CancellationError()
        } catch {
            log(dir, "transcription failed: \(error)")
            TranscriptionFailurePolicy.record(error, for: dir, engine: current)
            await releaseEngine()
            throw error
        }
        await releaseEngine()
    }

    private func takeProcessingTurn() async {
        if processing {
            await withCheckedContinuation { processingWaiters.append($0) }
        } else {
            processing = true
        }
    }

    private func releaseProcessingTurn() {
        if processingWaiters.isEmpty {
            processing = false
        } else {
            processingWaiters.removeFirst().resume()
        }
    }

    /// One session from end to end: the transcript, then the banner and the
    /// hook that say it happened.
    private func transcribeAndAnnounce(_ dir: URL) async throws {
        // Before the claim and before the engine: nothing about this session
        // is decided while the answers are in a file that cannot be read.
        try Config.requireReadable()
        current = nil
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path),
           !TranscriptVersions.isRequested(dir),
           let state = DiarizationState.read(dir), state.isOutstanding {
            guard Config.localDiarizationEnabled() || state.request.explicit else {
                throw AlreadyTranscribed()
            }
            do {
                if try await runDiarization(dir, explicit: state.request.explicit) {
                    await PostProcessor.finish(dir)
                    notifyUser(
                        title: localised("amanu — speakers updated", "amanu — говорящие обновлены"),
                        body: dir.lastPathComponent, opening: dir)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { log(dir, "diarization remains unfinished: \(error)") }
            return
        }
        var fallbackUsed = false
        let engine: TranscriptionEngine
        do {
            engine = try await transcribe(dir)
        } catch let done as AlreadyTranscribed {
            throw done
        } catch {
            // The network can go away between the reachability probe and the
            // upload. One retry on the local engine, so a dropped connection
            // costs minutes rather than the transcript — this session's
            // minutes only: the next one is resolved afresh, and gets the
            // cloud again if the cloud is back.
            guard EngineResolver.configuredEngine(for: dir) == "auto",
                  engines.canFallBackLocally,
                  let failed = current, EngineResolver.isCloud(failed),
                  TranscriptionFailurePolicy.looksLikeNetworkTrouble(error)
            else { throw error }
            let local = Config.transcriptionLocalEngine()
            log(dir, "cloud transcription failed (\(error)) — retrying locally")
            Analytics.track(.transcriptFallback, [
                .fromEngine: .text(failed.name),
                .toEngine: .text(local),
                .reason: .text(Analytics.reason(for: error).rawValue),
            ])
            fallbackUsed = true
            engine = try await transcribe(dir, with: try await engines.localFallback())
        }
        // After the transcript, never instead of it: transcript.json is the
        // completion marker, so anything that runs before it risks retiring a
        // session that has no transcript. Naming and summarizing both just log
        // when they can't run, and are picked up again by a later sweep.
        //
        // Outside `transcribe` rather than at the end of it because both take
        // the session's claim, and a claim held while asking for a second one
        // would refuse itself.
        Analytics.track(.transcriptFinished, [
            .engine: .text(engine.name),
            .model: .text(AnalyticsCatalogue.transcriptionModel(
                engine: engine.name, provenance: engine.model)),
            .fallbackUsed: .flag(fallbackUsed),
        ])
        if DiarizationState.read(dir)?.isFinal == false {
            notifyUser(
                title: localised("amanu — transcript ready; speakers pending",
                                 "amanu — расшифровка готова; говорящие определяются"),
                body: dir.lastPathComponent, opening: dir)
            StopHook.fireIfOwed(dir, command: onStop())
            if let state = DiarizationState.read(dir),
               state.status == .pending && state.attempts == 0 {
                do {
                    if try await runDiarization(dir, explicit: state.request.explicit) {
                        await PostProcessor.finish(dir)
                        notifyUser(
                            title: localised("amanu — speakers updated", "amanu — говорящие обновлены"),
                            body: dir.lastPathComponent, opening: dir)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { log(dir, "diarization remains unfinished: \(error)") }
            }
        } else {
            await PostProcessor.finish(dir)
            notifyUser(
                title: localised("amanu — transcript ready", "amanu — расшифровка готова"),
                body: dir.lastPathComponent, opening: dir)
            StopHook.fireIfOwed(dir, command: onStop())
        }
    }

    private func releaseEngine() async {
        await engines.release()
    }

    /// The session had its transcript by the time its claim was taken.
    private struct AlreadyTranscribed: Error {}

    private struct EmptyTranscript: TranscriptionFailure, CustomStringConvertible {
        var isPermanent: Bool { true }
        var description: String { "No speech was recognized; audio kept for a manual retry." }
    }

    private struct DiarizationUnavailable: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    private struct ASRPreparationUnavailable: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// Explicit retry is independent of the global automatic switch. It may
    /// finish a provisional transcript without asking the recognizer again.
    func diarizeNow(_ dir: URL) async throws {
        await takeProcessingTurn()
        defer { releaseProcessingTurn() }
        do {
            try await diarizeNowClaimed(dir)
            await releaseEngine()
        } catch {
            await releaseEngine()
            throw error
        }
    }

    private func diarizeNowClaimed(_ dir: URL) async throws {
        try Config.requireReadable()
        guard let transcript = PostProcessor.readTranscript(dir) else {
            let engine = Config.transcriptionLocalEngine()
            try DiarizationState(request: .init(engine: engine,
                                                threshold: Config.diarizationThreshold(),
                                                explicit: true), status: .pending).write(to: dir)
            try await transcribeAndAnnounce(dir)
            guard DiarizationState.read(dir)?.status == .completed else {
                throw DiarizationUnavailable(reason: DiarizationState.read(dir)?.reason
                    ?? "local speakers are still unfinished")
            }
            return
        }
        guard Config.localEngines.contains(transcript.engine) else {
            throw DiarizationUnavailable(reason: "this transcript does not use a local ASR engine")
        }
        try SessionClaim.acquire(dir, stage: .transcribe)
        do {
            try TranscriptVersions.recover(dir)
            let old = DiarizationState.read(dir)
            if let old, old.status == .completed {
                if try await completedGenerationMatches(dir, transcript: transcript,
                                                        state: old) {
                    SessionClaim.release(dir)
                    return
                }
                guard SessionInventory.item(for: dir)?.hasAudio == true else {
                    throw DiarizationUnavailable(reason: "source audio is no longer available")
                }
                // Archive the completed generation before writing the new
                // pending request into meta.json. Its version keeps the old
                // status, names and timeline even if the retry later fails.
                _ = try TranscriptVersions.archiveCurrent(dir)
            }
            var pending = DiarizationState(
                request: .init(engine: transcript.engine,
                               threshold: Config.diarizationThreshold(), explicit: true),
                status: .pending)
            if let old, old.status != .completed, old.status != .failed,
               old.request.threshold == pending.request.threshold {
                pending.attempts = old.attempts
                pending.fingerprint = old.fingerprint
            }
            if old?.status == .completed { pending.reason = "speaker model or options changed" }
            try pending.write(to: dir)
            SessionClaim.release(dir)
        } catch {
            SessionClaim.release(dir)
            throw error
        }
        let updated = try await runDiarization(dir, explicit: true)
        if updated {
            await PostProcessor.finish(dir)
            notifyUser(title: localised("amanu — speakers updated", "amanu — говорящие обновлены"),
                       body: dir.lastPathComponent, opening: dir)
        }
    }

    /// A completed result is a no-op only when the current model, ASR options,
    /// source content and threshold still describe that exact generation.
    private func completedGenerationMatches(
        _ dir: URL, transcript: Transcript, state: DiarizationState
    ) async throws -> Bool {
        let currentMeta = try SessionMeta.read(from: dir)
        guard let remote = currentMeta.tracks.first(where: {
            $0.speaker == "them" || $0.speaker == "speaker"
        }) else { return state.request.threshold == Config.diarizationThreshold() }
        guard let asr = DiarizationArtifacts.readASR(dir),
              let track = asr.tracks.first(where: { $0.speaker == remote.speaker }),
              let generation = state.fingerprint
        else { return false }
        let engine = try await engines.local(named: transcript.engine,
                                             wordTimings: true, prepare: false)
        current = engine
        let options = Self.asrOptionsFingerprint(engine: engine)
        guard transcript.engine == engine.name, transcript.model == engine.model,
              asr.engine == engine.name, asr.model == engine.model,
              asr.optionsFingerprint == options else {
            throw DiarizationUnavailable(reason: "ASR model or options changed; use --again")
        }
        try Self.validateCachedTracks(asr, meta: currentMeta, in: dir)
        if track.originFile == remote.file,
           track.originChannel == remote.channel,
           let origin = track.originFingerprint,
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(remote.file).path),
           try Self.originFingerprint(remote, in: dir) != origin {
            throw DiarizationUnavailable(reason: "source audio changed; use --again")
        }
        let sourceURL = dir.appendingPathComponent("diarization-source-\(remote.speaker).caf")
        let sourceFingerprint: String
        if FileManager.default.fileExists(atPath: sourceURL.path) {
            guard (try? sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                    != true else { throw DiarizationAudioSource.SourceError.invalidPath }
            let source = DiarizationAudioSource.Prepared(
                url: sourceURL, trackID: remote.speaker, sampleRate: 16_000,
                sampleCount: track.sampleCount, clock: track.clock,
                fingerprint: track.sourceFingerprint)
            try DiarizationAudioSource.verify(source)
            sourceFingerprint = source.fingerprint
        } else {
            guard SessionInventory.item(for: dir)?.hasAudio != true else {
                throw DiarizationUnavailable(reason: "durable source audio is missing; use --again")
            }
            sourceFingerprint = track.sourceFingerprint
        }
        let model = try await modelFingerprint()
        let diarizationOptions = DiarizationArtifacts.hash(
            "alignment-v1", String(Config.diarizationThreshold()))
        return DiarizationArtifacts.hash(sourceFingerprint, model,
            diarizationOptions, options) == generation
    }

    /// Every cached side is part of the transcript, even though only the
    /// remote side feeds clustering. A changed microphone cannot be carried
    /// forward under an unchanged remote-speaker fingerprint.
    private static func validateCachedTracks(
        _ asr: DiarizationArtifacts.ASR, meta: SessionMeta, in dir: URL
    ) throws {
        let fm = FileManager.default
        for cached in asr.tracks {
            guard let current = meta.track(for: cached.speaker) else {
                throw DiarizationUnavailable(reason: "recording tracks changed; use --again")
            }
            if cached.originFile == current.file,
               cached.originChannel == current.channel,
               let origin = cached.originFingerprint,
               fm.fileExists(atPath: dir.appendingPathComponent(current.file).path),
               try originFingerprint(current, in: dir) != origin {
                throw DiarizationUnavailable(reason: "recording audio changed; use --again")
            }
            let durable = dir.appendingPathComponent("diarization-source-\(cached.speaker).caf")
            if fm.fileExists(atPath: durable.path) {
                guard (try? durable.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                        != true else { throw DiarizationAudioSource.SourceError.invalidPath }
                try DiarizationAudioSource.verify(.init(
                    url: durable, trackID: cached.speaker, sampleRate: 16_000,
                    sampleCount: cached.sampleCount, clock: cached.clock,
                    fingerprint: cached.sourceFingerprint))
            } else if fm.fileExists(atPath: dir.appendingPathComponent(current.file).path) {
                throw DiarizationUnavailable(reason: "durable recording source is missing; use --again")
            }
        }
    }

    func skipDiarization(_ dir: URL) async throws {
        await takeProcessingTurn()
        defer { releaseProcessingTurn() }
        try SessionClaim.acquire(dir, stage: .transcribe)
        do {
            try TranscriptVersions.recover(dir)
            guard PostProcessor.readTranscript(dir) != nil else {
                throw DiarizationUnavailable(reason: "transcript is not ready; source audio must be kept")
            }
            if var state = DiarizationState.read(dir), state.status != .completed {
                state.status = .skipped
                state.reason = nil
                try state.write(to: dir)
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(
                    DiarizationArtifacts.candidateFile))
                TrackCompressor.settle(sessionDir: dir)
                TranscriptionScratch.remove(in: dir)
            }
            SessionClaim.release(dir)
        } catch {
            SessionClaim.release(dir)
            throw error
        }
        await PostProcessor.finish(dir)
        StopHook.fireIfOwed(dir, command: onStop())
    }

    @discardableResult
    private func runDiarization(_ dir: URL, explicit: Bool) async throws -> Bool {
        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }
        try TranscriptVersions.recover(dir)
        TranscriptionScratch.remove(in: dir)
        guard var state = DiarizationState.read(dir),
              let provisional = PostProcessor.readTranscript(dir) else { return false }
        if state.status == .completed || state.status == .skipped || state.status == .notApplicable {
            return false
        }
        if !explicit && !Config.localDiarizationEnabled() { return false }
        let currentMeta = try SessionMeta.read(from: dir)
        guard let track = currentMeta.tracks.first(where: {
            $0.speaker == "them" || $0.speaker == "speaker"
        }) else {
            state.status = .completed
            try state.write(to: dir)
            TrackCompressor.settle(sessionDir: dir)
            return true
        }

        let asr = DiarizationArtifacts.readASR(dir)
        if let asr { try Self.validateCachedTracks(asr, meta: currentMeta, in: dir) }
        let sourceFile = dir.appendingPathComponent("diarization-source-\(track.speaker).caf")
        if (try? sourceFile.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw DiarizationAudioSource.SourceError.invalidPath
        }
        let cachedTrack = asr?.tracks.first { $0.speaker == track.speaker }
        if let cachedTrack, let original = cachedTrack.originFingerprint,
           cachedTrack.originFile == track.file,
           cachedTrack.originChannel == track.channel {
            let originFile = dir.appendingPathComponent(track.file)
            if FileManager.default.fileExists(atPath: originFile.path),
               (try Self.originFingerprint(track, in: dir)) != original {
                state.status = .partial
                state.reason = "the source audio changed; re-transcribe before assigning speakers"
                try state.write(to: dir)
                throw DiarizationUnavailable(reason: state.reason!)
            }
        }
        let source: DiarizationAudioSource.Prepared
        do {
            if let cachedTrack, FileManager.default.fileExists(atPath: sourceFile.path) {
                let candidate = DiarizationAudioSource.Prepared(
                    url: sourceFile, trackID: track.speaker, sampleRate: 16_000,
                    sampleCount: cachedTrack.sampleCount, clock: cachedTrack.clock,
                    fingerprint: cachedTrack.sourceFingerprint)
                if (try? DiarizationAudioSource.verify(candidate)) != nil {
                    source = candidate
                } else {
                    source = try prepareSource(track, audio: dir, session: dir)
                }
            } else {
                source = try prepareSource(track, audio: dir, session: dir)
            }
        } catch {
            state.status = .partial
            state.reason = "source unavailable: \(error)"
            try state.write(to: dir)
            throw error
        }
        if let cachedTrack, cachedTrack.sourceFingerprint != source.fingerprint {
            state.status = .partial
            state.reason = "source audio changed; re-transcribe before assigning speakers"
            try state.write(to: dir)
            throw DiarizationUnavailable(reason: state.reason!)
        }

        let engine: TranscriptionEngine
        let model: String
        do {
            engine = try await engines.local(named: state.request.engine,
                                              wordTimings: true, prepare: false)
            current = engine
            model = try await modelFingerprint()
        } catch {
            state.deferForEnvironment("model unavailable: \(error)")
            try state.write(to: dir)
            throw error
        }
        let asrOptions = Self.asrOptionsFingerprint(engine: engine)
        guard provisional.engine == engine.name, provisional.model == engine.model,
              asr == nil || (asr?.engine == engine.name && asr?.model == engine.model
                            && asr?.optionsFingerprint == asrOptions) else {
            state.status = .partial
            state.reason = "ASR model or options changed; re-transcribe before assigning speakers"
            try state.write(to: dir)
            throw DiarizationUnavailable(reason: state.reason!)
        }
        let options = DiarizationArtifacts.hash("alignment-v1", String(state.request.threshold))
        let fingerprint = DiarizationArtifacts.hash(
            source.fingerprint, model, options, asrOptions)
        if !explicit && state.attempts >= 3 && state.fingerprint == fingerprint { return false }
        let priorHash = try DiarizationArtifacts.transcriptHash(provisional)
        let candidateURL = dir.appendingPathComponent(DiarizationArtifacts.candidateFile)
        let timelineURL = dir.appendingPathComponent(DiarizationArtifacts.timelineFile)
        let availableTimelines = [candidateURL, timelineURL]
            .compactMap { try? Data(contentsOf: $0) }.compactMap {
            try? JSONDecoder().decode(
                DiarizationArtifacts.Timeline<LocalDiarizationPipeline.Result>.self, from: $0)
            }
        let cachedTimeline = availableTimelines.first {
            $0.transcriptSHA256 == priorHash && $0.generationFingerprint == fingerprint
        }
        let reusableTurnASR = availableTimelines.first {
            $0.transcriptSHA256 == priorHash
                && $0.result.sourceFingerprint == source.fingerprint
                && $0.result.asrOptionsFingerprint == asrOptions
        }?.result.turnASR
        let result: LocalDiarizationPipeline.Result
        if let cachedTimeline, cachedTimeline.schemaVersion == 1,
           cachedTimeline.transcriptSHA256 == priorHash,
           cachedTimeline.generationFingerprint == fingerprint,
           cachedTimeline.result.sourceFingerprint == source.fingerprint,
           cachedTimeline.result.modelFingerprint == model,
           cachedTimeline.result.optionsFingerprint == options,
           cachedTimeline.result.asrOptionsFingerprint == asrOptions {
            result = cachedTimeline.result
        } else {
            let runtime = diarizerFactory(
                DiarizationSettings(enabled: true, threshold: state.request.threshold))
            do {
                try await runtime.prepare()
            } catch {
                state.deferForEnvironment("model unavailable: \(error)")
                try state.write(to: dir)
                throw error
            }
            state.beginInference(fingerprint: fingerprint)
            var runPersisted = false
            do {
                try state.write(to: dir)
                runPersisted = true
                result = try await LocalDiarizationPipeline.run(
                    source: source, engine: engine, runtime: runtime,
                    settings: DiarizationSettings(enabled: true, threshold: state.request.threshold),
                    cachedASR: asr?.cached(
                        speaker: track.speaker, sourceFingerprint: source.fingerprint,
                        optionsFingerprint: asrOptions, engine: engine.name, model: engine.model),
                    cachedTurnASR: reusableTurnASR,
                    prepareASR: { [engines] in
                        do { try await engines.prepare(engine) }
                        catch is CancellationError { throw CancellationError() }
                        catch { throw ASRPreparationUnavailable(reason: "ASR model unavailable: \(error)") }
                    },
                    modelFingerprint: model, optionsFingerprint: options,
                    asrOptionsFingerprint: asrOptions)
                try Task.checkCancellation()
                await runtime.release()
            } catch is CancellationError {
                await runtime.release()
                state.attempts = max(0, state.attempts - 1)
                state.status = .pending
                try state.write(to: dir)
                throw CancellationError()
            } catch let unavailable as ASRPreparationUnavailable {
                await runtime.release()
                state.attempts = max(0, state.attempts - 1)
                state.deferForEnvironment(unavailable.reason)
                try state.write(to: dir)
                throw unavailable
            } catch {
                await runtime.release()
                if runPersisted {
                    state.failInference("inference failed: \(error)")
                    try state.write(to: dir)
                } else {
                    state.attempts = max(0, state.attempts - 1)
                    state.status = .pending
                }
                throw error
            }
            try DiarizationArtifacts.encode(DiarizationArtifacts.Timeline(
                transcriptSHA256: priorHash, generationFingerprint: fingerprint,
                result: result)).write(to: candidateURL, options: .atomic)
        }

        let hadRemoteWords = provisional.segments.contains {
            $0.speaker != "me" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if result.segments.isEmpty && hadRemoteWords {
            state.status = .partial
            state.reason = "the speaker model found no speech in audio with recognized words"
            try state.write(to: dir)
            throw DiarizationUnavailable(reason: state.reason!)
        }
        let unchangedLocal = provisional.segments.filter { $0.speaker == "me" }
        let segments = (unchangedLocal + result.segments).sorted { $0.start_ms < $1.start_ms }
        let created = ISO8601DateFormatter().string(from: Date())
        let final = Transcript(engine: provisional.engine, model: provisional.model,
                               created_at: created, segments: segments)
        state.status = .completed
        state.reason = nil
        state.confirmedSpeakers = Set(segments.map(\.speaker).filter {
            !SpeakerNames.isUnknown($0)
        }).count
        state.hasUnknown = segments.contains { SpeakerNames.isUnknown($0.speaker) }
        state.rejectedTurnCount = result.rejectedTurnCount
        let finalTimeline = DiarizationArtifacts.Timeline(
            transcriptSHA256: try DiarizationArtifacts.transcriptHash(final),
            generationFingerprint: fingerprint, result: result)
        let finalHash = try DiarizationArtifacts.transcriptHash(final)
        let originFingerprint: String
        if let stored = cachedTrack?.originFingerprint { originFingerprint = stored }
        else { originFingerprint = try Self.originFingerprint(track, in: dir) }
        let newRemoteASR = DiarizationArtifacts.ASR.Track(
            speaker: track.speaker, sourceFingerprint: source.fingerprint,
            sampleCount: source.sampleCount, clock: source.clock,
            originFingerprint: originFingerprint,
            originFile: cachedTrack?.originFile ?? track.file,
            originChannel: cachedTrack?.originChannel ?? track.channel,
            sourceKind: cachedTrack?.sourceKind ?? (track.channel == nil ? "raw" : "archive"),
            segments: result.asr)
        let finalASR = (asr ?? DiarizationArtifacts.ASR(
            transcriptSHA256: priorHash, engine: engine.name, model: engine.model,
            optionsFingerprint: asrOptions, tracks: []))
            .replacing(newRemoteASR, transcriptSHA256: finalHash)
        do {
            try TranscriptVersions.commit(
                final, to: dir,
                sidecars: [DiarizationArtifacts.timelineFile:
                    try DiarizationArtifacts.encode(finalTimeline),
                    DiarizationArtifacts.asrFile: try DiarizationArtifacts.encode(finalASR)],
                metadata: [DiarizationState.key:
                    try JSONSerialization.jsonObject(with: DiarizationArtifacts.encode(state))],
                preserveRemoteNames: false)
        } catch {
            state.status = .partial
            state.reason = "could not publish speaker result: \(error)"
            try? state.write(to: dir)
            throw error
        }
        TrackCompressor.settle(sessionDir: dir)
        try? FileManager.default.removeItem(at: candidateURL)
        TranscriptionScratch.remove(in: dir)
        return true
    }

    /// Transcribe one session with the engine it asks for, or with `given`,
    /// and return the engine that did it.
    @discardableResult
    private func transcribe(
        _ dir: URL, with given: TranscriptionEngine? = nil
    ) async throws -> TranscriptionEngine {
        // The one place both routes into transcription meet: the app draining
        // its queue and `amanu process` given a folder by hand. Claiming here,
        // before an engine is prepared and long before anything is uploaded,
        // is what keeps two processes from paying twice for one recording.
        // Released in the `defer` so the throw and the local-engine retry give
        // the folder back as surely as the success does.
        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }
        try TranscriptVersions.recover(dir)
        // Asked again now that the folder is ours. A session can wait in the
        // queue while somebody else — `amanu process`, another entry for the
        // same folder — transcribes it, and the claim is what makes the
        // answer to "is there a transcript" stay true until we are done.
        if FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("transcript.json").path), !TranscriptVersions.isRequested(dir) {
            log(dir, "already transcribed — nothing to do")
            throw AlreadyTranscribed()
        }

        var meta = try SessionMeta.read(from: dir)
        let recordedMeta = meta
        var diarization = DiarizationState.read(dir)
        let engine: TranscriptionEngine
        if let given { engine = given }
        else if let diarization, diarization.request.explicit {
            engine = try await engines.local(named: diarization.request.engine,
                                             wordTimings: true)
        } else {
            engine = try await engines.engine(for: dir,
                wordTimings: Config.localDiarizationEnabled() || diarization != nil)
        }
        current = engine
        if var requested = diarization {
            if !Config.localEngines.contains(engine.name) || !Platform.supportsLocalModels {
                requested.status = .notApplicable
            } else if requested.request.engine != engine.name {
                requested = DiarizationState(request: .init(
                    engine: engine.name, threshold: requested.request.threshold,
                    explicit: requested.request.explicit), status: .pending)
            }
            diarization = requested
            try requested.write(to: dir)
        }
        if diarization == nil && Config.localDiarizationEnabled() {
            let applicable = Config.localEngines.contains(engine.name) && Platform.supportsLocalModels
            diarization = DiarizationState(
                request: .init(engine: engine.name, threshold: Config.diarizationThreshold()),
                status: applicable ? .pending : .notApplicable)
            try diarization?.write(to: dir)
        }

        var audioDirectory = dir
        var cleaned: OfflineEchoAudio.Result?
        defer { cleaned?.removeAudio() }
        if Config.offlineEchoCancellation(),
           let mic = meta.track(for: "me"), let system = meta.track(for: "them") {
            if let prepared = try await cancelEcho(in: dir, mic: mic, system: system) {
                cleaned = prepared
                audioDirectory = prepared.directory
                meta = SessionMeta(tracks: [
                    .init(file: "mic.caf", speaker: "me", offsetMs: 0, channel: nil),
                    .init(file: "system.caf", speaker: "them", offsetMs: 0, channel: nil),
                ], title: meta.title, attendees: meta.attendees, app: meta.app)
            }
        } else {
            SessionState.update(dir, with: ["audio_echo_cancellation": nil])
        }

        if engine.name == "gigaam", let state = diarization, state.status == .pending,
           try await transcribeGigaAfterTurns(
               dir: dir, audio: audioDirectory, meta: meta, engine: engine,
               state: state, cleaned: cleaned != nil) {
            return engine
        }
        diarization = DiarizationState.read(dir)

        let inputs = TranscriptionInputs(
            session: dir, audio: audioDirectory, meta: meta, engine: engine)
        var preparedSources: [String: DiarizationAudioSource.Prepared] = [:]
        if diarization?.retainsAudio == true,
           case .perTrack = engine.input {
            do {
                for track in meta.tracks {
                    let input = audioDirectory.appendingPathComponent(track.file)
                    guard FileManager.default.fileExists(atPath: input.path),
                          (track.channel != nil || !TranscriptionInputs.holdsNoAudio(input))
                    else { continue }
                    preparedSources[track.speaker] = try prepareSource(
                        track, audio: audioDirectory, session: dir)
                }
            } catch {
                preparedSources.removeAll()
                diarization?.status = .partial
                diarization?.reason = "could not prepare local audio: \(error)"
            }
        }
        var merged: [Transcript.Segment]
        var rawTracks: [TranscriptionInputs.PerTrackResult] = []
        var echoFilterRan = false
        var echoesDropped = 0
        switch engine.input {
        case .perTrack:
            if diarization?.retainsAudio == true {
                rawTracks = try await inputs.perTrackDetailed(prepared: preparedSources)
                merged = rawTracks.flatMap(\.transcript)
            } else {
                merged = try await inputs.perTrack()
            }
            merged.sort { $0.start_ms < $1.start_ms }
            // Only the per-track path can double-transcribe the far end: it
            // reads both tracks, and a raw mic recording through speakers has
            // their voice on it too. A diarizing engine sees the mix once, so
            // there's no duplicate for a filter to find.
            if Config.transcriptEchoFilter(), !meta.isSingleSource {
                echoFilterRan = true
                let before = merged.count
                merged = cleaned == nil ? EchoFilter.dropEchoes(merged) : EchoFilter.dropResidualEchoes(merged)
                echoesDropped = before - merged.count
                if merged.count != before {
                    log(dir, "echo filter dropped \(before - merged.count) "
                        + "mic segment(s) duplicating system audio")
                }
            }
        case .multichannel:
            merged = try await inputs.multichannel()
            merged.sort { $0.start_ms < $1.start_ms }
            if Config.transcriptEchoFilter(), !meta.isSingleSource {
                echoFilterRan = true
                let before = merged.count
                merged = cleaned == nil ? EchoFilter.dropEchoes(merged) : EchoFilter.dropResidualEchoes(merged)
                echoesDropped = before - merged.count
                if echoesDropped > 0 {
                    log(dir, "echo filter dropped \(echoesDropped) "
                        + "mic segment(s) duplicating system audio")
                }
            }
            merged = MultichannelSpeakerLabels.collapseSingleSides(merged)
        case .mixed:
            merged = try await inputs.mixed()
            merged.sort { $0.start_ms < $1.start_ms }
        }

        guard merged.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw EmptyTranscript()
        }

        let created = ISO8601DateFormatter()
        created.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: created.string(from: Date()),
            segments: merged
        )
        var sidecars: [String: Data?] = [
            DiarizationArtifacts.asrFile: nil,
            DiarizationArtifacts.timelineFile: nil,
        ]
        if var state = diarization, state.retainsAudio {
            do {
                let prepared = try rawTracks.map { pair in
                    if let source = preparedSources[pair.track.speaker] { return source }
                    return try self.prepareSource(pair.track, audio: audioDirectory, session: dir)
                }
                let options = Self.asrOptionsFingerprint(engine: engine)
                let tracks = try zip(rawTracks, prepared).map { item in
                    let (pair, source) = item
                    let recorded = recordedMeta.track(for: pair.track.speaker)
                    return DiarizationArtifacts.ASR.Track(
                        speaker: pair.track.speaker, sourceFingerprint: source.fingerprint,
                        sampleCount: source.sampleCount, clock: source.clock,
                        originFingerprint: try recorded.map {
                            try Self.originFingerprint($0, in: dir)
                        },
                        originFile: recorded?.file,
                        originChannel: recorded?.channel,
                        sourceKind: audioDirectory == dir
                            ? (pair.track.channel == nil ? "raw" : "archive") : "aec",
                        segments: pair.offsetApplied ? pair.segments
                            : Self.onSessionClock(pair.segments, clock: source.clock))
                }
                sidecars[DiarizationArtifacts.asrFile] = try DiarizationArtifacts.encode(
                    DiarizationArtifacts.ASR(
                                             transcriptSHA256: try DiarizationArtifacts.transcriptHash(transcript),
                                             engine: engine.name, model: engine.model,
                                             optionsFingerprint: options, tracks: tracks))
                if !tracks.contains(where: { $0.speaker == "them" || $0.speaker == "speaker" }) {
                    state.status = .completed
                    state.confirmedSpeakers = tracks.contains { $0.speaker == "me" } ? 1 : 0
                }
            } catch {
                state.status = .partial
                state.reason = "could not prepare local audio: \(error)"
            }
            diarization = state
        }
        var metadata: [String: Any?] = [
            StopHook.key: StopHook.owed,
            "transcription_input": engine.input.metadataName,
            "echo_filter": [
                "ran": echoFilterRan,
                "dropped_segments": echoesDropped,
                "mode": cleaned == nil ? "raw_audio" : "residual_exact_phrases",
            ],
        ]
        if let diarization {
            metadata[DiarizationState.key] = try JSONSerialization.jsonObject(
                with: DiarizationArtifacts.encode(diarization))
        }
        try TranscriptVersions.commit(transcript, to: dir, sidecars: sidecars,
                                      metadata: metadata,
                                      preserveRemoteNames: diarization == nil)
        log(dir, "done — \(merged.count) segments")

        // The audio was recorded uncompressed so it would survive a crash, and
        // that only had to hold until the transcript existed. It does now, so
        // the tracks become one stereo archive — or are deleted, if
        // `keep_audio` is off.
        //
        // Before naming and summarizing rather than after, because both of
        // those want a language model and can sit for hours waiting for one,
        // and neither reads the audio: they work from the transcript. Making
        // the gigabyte wait for a model it isn't going to be shown to would be
        // paying twice for nothing.
        TrackCompressor.settle(sessionDir: dir)
        TranscriptionScratch.remove(in: dir)
        return engine
    }

    /// Clean acoustic echo out of a copy of the microphone track, or nil when
    /// that could not be done.
    ///
    /// Echo cancellation improves a transcript; it is not what makes one. It
    /// is on by default, and a failure anywhere in it — a LocalVQE library
    /// missing from the bundle or refusing to load, a model that fails its
    /// checksum, a hop of non-finite audio, a copy that came out short — used
    /// to fail the whole transcription, be retried three times and retire a
    /// recording whose tracks were perfectly good. Now the tracks are
    /// transcribed as recorded, the text-level echo filter does what it did
    /// before offline cancellation existed, and meta.json and the log say
    /// what was skipped and why.
    private func cancelEcho(
        in dir: URL, mic: SessionMeta.Track, system: SessionMeta.Track
    ) async throws -> OfflineEchoAudio.Result? {
        let microphone = OfflineEchoAudio.Source(
            url: dir.appendingPathComponent(mic.file), channel: mic.channel ?? 0, offsetMs: mic.offsetMs)
        let reference = OfflineEchoAudio.Source(
            url: dir.appendingPathComponent(system.file), channel: system.channel ?? 0, offsetMs: system.offsetMs)
        let factory = echoCanceller
        log(dir, "removing acoustic echo from a microphone copy before transcription")
        let worker = Task.detached(priority: .utility) {
            try OfflineEchoAudio.prepare(
                microphone: microphone, system: reference, in: dir, cancellerFactory: factory)
        }
        let prepared: OfflineEchoAudio.Result
        do {
            prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            log(dir, "echo cancellation skipped — \(error); transcribing the tracks as recorded")
            SessionState.update(dir, with: ["audio_echo_cancellation": [
                "processor": LocalVQEAssets.processorVersion,
                "skipped": "\(error)",
            ]])
            return nil
        }
        SessionState.update(dir, with: ["audio_echo_cancellation": [
            "processor": LocalVQEAssets.processorVersion,
            "model_sha256": LocalVQEAssets.modelSHA256,
            "sample_rate": EchoCanceller.sampleRate,
            "frames": prepared.frames,
            "cache_directory": prepared.directory.lastPathComponent,
        ]])
        log(dir, "audio echo cancellation complete; original tracks kept")
        return prepared
    }

    private func prepareSource(
        _ track: SessionMeta.Track, audio: URL, session: URL
    ) throws -> DiarizationAudioSource.Prepared {
        let root = audio.standardizedFileURL.resolvingSymlinksInPath()
        let input = root.appendingPathComponent(track.file).standardizedFileURL.resolvingSymlinksInPath()
        guard input.path.hasPrefix(root.path + "/") else {
            throw DiarizationAudioSource.SourceError.invalidPath
        }
        let destination = session.appendingPathComponent(
            "diarization-source-\(track.speaker).caf")
        if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw DiarizationAudioSource.SourceError.invalidPath
        }
        let clock: DiarizationAudioSource.Clock = track.channel != nil || audio != session
            ? .sessionAligned : .recorded(offsetMs: track.offsetMs)
        if case .recorded(let offsetMs) = clock {
            let duration = SessionState.value(session, "duration_seconds") as? Int
            let bound = duration.map { min(max(0, $0), 86_399) * 1_000 + 1_000 }
                ?? 86_400_000
            guard offsetMs >= 0, offsetMs <= bound else {
                throw DiarizationAudioSource.SourceError.invalidOffset
            }
        }
        return try DiarizationAudioSource.prepare(
            input: input, channel: track.channel, trackID: track.speaker,
            clock: clock, destination: destination)
    }

    private static func asrOptionsFingerprint(engine: TranscriptionEngine) -> String {
        DiarizationArtifacts.hash(engine.name, engine.model, engine.optionsFingerprint)
    }

    private static func originFingerprint(_ track: SessionMeta.Track, in dir: URL) throws -> String {
        let root = dir.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(track.file)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            throw DiarizationAudioSource.SourceError.invalidPath
        }
        return DiarizationArtifacts.hash(
            track.file, String(track.channel ?? -1), String(track.offsetMs),
            try DiarizationArtifacts.fileHash(file))
    }

    private static func onSessionClock(
        _ segments: [TranscriptSegment], clock: DiarizationAudioSource.Clock
    ) -> [TranscriptSegment] {
        guard case .recorded(let offsetMs) = clock else { return segments }
        let offset = TimeInterval(offsetMs) / 1000
        return segments.map { segment in
            TranscriptSegment(
                start: segment.start + offset, end: segment.end + offset,
                text: segment.text, speaker: segment.speaker,
                words: segment.words?.map {
                    TranscriptWord(start: $0.start + offset, end: $0.end + offset, text: $0.text)
                })
        }
    }

    /// GigaAM has no word clock. On the healthy route the diarizer cuts
    /// disjoint turns first and GigaAM recognizes those turns only.
    private func transcribeGigaAfterTurns(
        dir: URL, audio: URL, meta: SessionMeta, engine: TranscriptionEngine,
        state initial: DiarizationState, cleaned: Bool
    ) async throws -> Bool {
        guard let remote = meta.tracks.first(where: {
            $0.speaker == "them" || $0.speaker == "speaker"
        }) else { return false }
        let recordedMeta = try SessionMeta.read(from: dir)
        var state = initial
        let source: DiarizationAudioSource.Prepared
        do {
            source = try prepareSource(remote, audio: audio, session: dir)
        } catch {
            state.status = .partial
            state.reason = "source unavailable: \(error)"
            try state.write(to: dir)
            return false
        }
        let model: String
        let runtime = diarizerFactory(
            DiarizationSettings(enabled: true, threshold: state.request.threshold))
        do {
            model = try await modelFingerprint()
            try await runtime.prepare()
        } catch {
            state.deferForEnvironment("model unavailable: \(error)")
            try state.write(to: dir)
            return false
        }
        let asrOptions = Self.asrOptionsFingerprint(engine: engine)
        let options = DiarizationArtifacts.hash("alignment-v1", String(state.request.threshold))
        let generationFingerprint = DiarizationArtifacts.hash(
            source.fingerprint, model, options, asrOptions)
        state.beginInference(fingerprint: generationFingerprint)
        let result: LocalDiarizationPipeline.Result
        var runPersisted = false
        do {
            try state.write(to: dir)
            runPersisted = true
            result = try await LocalDiarizationPipeline.run(
                source: source, engine: engine, runtime: runtime,
                settings: DiarizationSettings(enabled: true, threshold: state.request.threshold),
                modelFingerprint: model, optionsFingerprint: options,
                asrOptionsFingerprint: asrOptions)
            try Task.checkCancellation()
            await runtime.release()
        } catch is CancellationError {
            await runtime.release()
            state.attempts = max(0, state.attempts - 1)
            state.status = .pending
            try state.write(to: dir)
            throw CancellationError()
        } catch {
            await runtime.release()
            if runPersisted {
                state.failInference("inference failed: \(error)")
                try state.write(to: dir)
            } else {
                state.attempts = max(0, state.attempts - 1)
                state.status = .pending
            }
            return false
        }

        var micTracks: [TranscriptionInputs.PerTrackResult] = []
        var micSource: DiarizationAudioSource.Prepared?
        if let mic = meta.track(for: "me") {
            let micURL = audio.appendingPathComponent(mic.file)
            if FileManager.default.fileExists(atPath: micURL.path),
               (mic.channel != nil || !TranscriptionInputs.holdsNoAudio(micURL)) {
                let micOnly = SessionMeta(tracks: [mic], title: meta.title,
                                          attendees: meta.attendees, app: meta.app)
                let preparedMic = try prepareSource(mic, audio: audio, session: dir)
                micSource = preparedMic
                micTracks = try await TranscriptionInputs(
                    session: dir, audio: audio, meta: micOnly, engine: engine)
                    .perTrackDetailed(prepared: ["me": preparedMic])
            }
        }
        let local = micTracks.flatMap(\.transcript)
        var segments = (local + result.segments).sorted { $0.start_ms < $1.start_ms }
        let beforeEchoFilter = segments.count
        if Config.transcriptEchoFilter(), !meta.isSingleSource {
            segments = cleaned ? EchoFilter.dropResidualEchoes(segments)
                               : EchoFilter.dropEchoes(segments)
        }
        let echoesDropped = beforeEchoFilter - segments.count
        guard segments.contains(where: { !$0.text.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty }) else { throw EmptyTranscript() }
        var tracks = [DiarizationArtifacts.ASR.Track(
            speaker: remote.speaker, sourceFingerprint: source.fingerprint,
            sampleCount: source.sampleCount, clock: source.clock,
            originFingerprint: try recordedMeta.track(for: remote.speaker).map {
                try Self.originFingerprint($0, in: dir)
            },
            originFile: recordedMeta.track(for: remote.speaker)?.file,
            originChannel: recordedMeta.track(for: remote.speaker)?.channel,
            sourceKind: audio == dir ? (remote.channel == nil ? "raw" : "archive") : "aec",
            segments: result.asr)]
        if let micSource {
            tracks += try micTracks.map {
                DiarizationArtifacts.ASR.Track(
                    speaker: "me", sourceFingerprint: micSource.fingerprint,
                    sampleCount: micSource.sampleCount, clock: micSource.clock,
                    originFingerprint: try recordedMeta.track(for: "me").map {
                        try Self.originFingerprint($0, in: dir)
                    },
                    originFile: recordedMeta.track(for: "me")?.file,
                    originChannel: recordedMeta.track(for: "me")?.channel,
                    sourceKind: audio == dir ? (meta.track(for: "me")?.channel == nil
                        ? "raw" : "archive") : "aec",
                    segments: $0.offsetApplied ? $0.segments
                        : Self.onSessionClock($0.segments, clock: micSource.clock))
            }
        }
        let created = ISO8601DateFormatter().string(from: Date())
        let transcript = Transcript(engine: engine.name, model: engine.model,
                                    created_at: created, segments: segments)
        state.status = .completed
        state.reason = nil
        state.confirmedSpeakers = Set(segments.map(\.speaker).filter {
            !SpeakerNames.isUnknown($0)
        }).count
        state.hasUnknown = segments.contains { SpeakerNames.isUnknown($0.speaker) }
        state.rejectedTurnCount = result.rejectedTurnCount
        let asr = DiarizationArtifacts.ASR(
            transcriptSHA256: try DiarizationArtifacts.transcriptHash(transcript),
            engine: engine.name, model: engine.model,
            optionsFingerprint: asrOptions, tracks: tracks)
        let timeline = DiarizationArtifacts.Timeline(
            transcriptSHA256: try DiarizationArtifacts.transcriptHash(transcript),
            generationFingerprint: generationFingerprint, result: result)
        try TranscriptVersions.commit(
            transcript, to: dir,
            sidecars: [DiarizationArtifacts.asrFile: try DiarizationArtifacts.encode(asr),
                       DiarizationArtifacts.timelineFile: try DiarizationArtifacts.encode(timeline)],
            metadata: [DiarizationState.key:
                try JSONSerialization.jsonObject(with: DiarizationArtifacts.encode(state)),
                       StopHook.key: StopHook.owed,
                       "transcription_input": engine.input.metadataName,
                       "echo_filter": [
                           "ran": Config.transcriptEchoFilter() && !meta.isSingleSource,
                           "dropped_segments": echoesDropped,
                           "mode": cleaned ? "residual_exact_phrases" : "raw_audio",
                       ]],
            preserveRemoteNames: false)
        TrackCompressor.settle(sessionDir: dir)
        TranscriptionScratch.remove(in: dir)
        return true
    }

    private func log(_ dir: URL, _ message: String) {
        appendSessionLog(message, to: dir)
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
