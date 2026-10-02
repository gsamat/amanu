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

    typealias EchoCancellerFactory = @Sendable () throws -> EchoCanceller

    /// `engine` is one settled on in advance rather than chosen for the
    /// machine at the moment there is work. Only tests pass one: everything
    /// real wants the configured answer, and wants it decided late.
    init(engine: TranscriptionEngine? = nil,
         onStop: @escaping @Sendable () -> String? = { Config.onStop() },
         echoCanceller: @escaping EchoCancellerFactory = { try EchoCanceller() }) {
        engines = EngineResolver(fixed: engine)
        self.onStop = onStop
        self.echoCanceller = echoCanceller
    }

    init(engines: EngineResolver,
         onStop: @escaping @Sendable () -> String? = { Config.onStop() },
         echoCanceller: @escaping EchoCancellerFactory = { try EchoCanceller() }) {
        self.engines = engines
        self.onStop = onStop
        self.echoCanceller = echoCanceller
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
                    || TranscriptVersions.isRequested($0))
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
        } catch {
            log(dir, "transcription failed: \(error)")
            TranscriptionFailurePolicy.record(error, for: dir, engine: current)
            await releaseEngine()
            throw error
        }
        await releaseEngine()
    }

    /// One session from end to end: the transcript, then the banner and the
    /// hook that say it happened.
    private func transcribeAndAnnounce(_ dir: URL) async throws {
        // Before the claim and before the engine: nothing about this session
        // is decided while the answers are in a file that cannot be read.
        try Config.requireReadable()
        current = nil
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
        await PostProcessor.finish(dir)
        notifyUser(
            title: localised("amanu — transcript ready", "amanu — расшифровка готова"),
            body: dir.lastPathComponent,
            opening: dir)
        StopHook.fireIfOwed(dir, command: onStop())
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
        let engine: TranscriptionEngine
        if let given { engine = given } else { engine = try await engines.engine(for: dir) }
        current = engine

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

        let inputs = TranscriptionInputs(
            session: dir, audio: audioDirectory, meta: meta, engine: engine)
        var merged: [Transcript.Segment]
        var echoFilterRan = false
        var echoesDropped = 0
        switch engine.input {
        case .perTrack:
            merged = try await inputs.perTrack()
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
        try TranscriptVersions.commit(transcript, to: dir)
        SessionState.update(dir, with: [
            StopHook.key: StopHook.owed,
            "transcription_input": engine.input.metadataName,
            "echo_filter": [
                "ran": echoFilterRan,
                "dropped_segments": echoesDropped,
                "mode": cleaned == nil ? "raw_audio" : "residual_exact_phrases",
            ],
        ])
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

    private func log(_ dir: URL, _ message: String) {
        appendSessionLog(message, to: dir)
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}
