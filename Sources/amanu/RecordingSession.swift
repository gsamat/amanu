import Foundation

/// A session that is being recorded, as far as the filesystem can tell: the
/// folder, the process that claimed it, and when it started. `ownerIsAlive`
/// separates the two things an in-progress manifest can mean — a recording
/// happening right now, or one a crash left behind.
struct RecordingInProgress: Sendable {
    let dir: URL
    let pid: Int32
    /// Nil only when the manifest was written by something that did not put a
    /// readable `started` in it; every version of amanu does.
    let started: Date?
    let ownerIsAlive: Bool
}

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — speech models do better on clean single-source
/// audio, and two tracks give free two-party diarization.
@MainActor
final class RecordingSession {
    enum StartFailure: Error, CustomStringConvertible {
        case systemAudio(Error)
        case microphone(Error)

        var analyticsComponent: String {
            switch self {
            case .systemAudio: return "system_audio"
            case .microphone: return "microphone"
            }
        }

        var description: String {
            switch self {
            case .systemAudio(let error): return "system audio: \(error)"
            case .microphone(let error): return "microphone: \(error)"
            }
        }

        /// What the banner says: that the call is not being recorded and what to
        /// try. The system's own error text is for the log, not for the person.
        var bannerBody: String {
            switch self {
            case .microphone:
                return localised(
                    "The microphone wouldn't start, so this call is not being recorded. "
                        + "If it keeps happening, quit and reopen amanu.",
                    "Микрофон не запустился, звонок не записывается. "
                        + "Если повторяется — закройте и снова откройте amanu.")
            case .systemAudio:
                return localised(
                    "System audio wouldn't start, so this call is not being recorded. "
                        + "Check the permission in amanu Setup.",
                    "Системный звук не запустился, звонок не записывается. "
                        + "Проверьте разрешение в настройках amanu.")
            }
        }
    }

    /// What started this session. Manual recordings are never stopped or
    /// discarded automatically: if you pressed the button, you meant it.
    enum Trigger: String {
        case manual
        case micActivity = "mic-activity"
        case calendar
    }

    let dir: URL
    let startedAt = Date()
    /// What we knew about the meeting when it started: calendar title, the app
    /// holding the microphone, attendees, link. Shapes the folder name and
    /// most of meta.json.
    let context: MeetingContext
    let trigger: Trigger

    var title: String? { context.title }

    private let mic: MicTrackRecorder
    private let system: SystemTrackRecorder

    /// How meta.json and the manifest reach the disk. A parameter so a test
    /// can make one of them fail — disk full is the case that matters, and it
    /// cannot be produced on demand any other way.
    typealias FileWriter = (Data, URL) throws -> Void
    private let writeFile: FileWriter

    typealias LiveAudioSink = LiveAudioBufferRelay.Sink

    /// Written at start, removed on clean stop. Its presence in a folder with
    /// no meta.json is what tells the next launch "this session was
    /// interrupted" — without it, a crash leaves perfectly good CAF files that
    /// nothing ever looks at again, because the transcription queue only
    /// considers folders that have a meta.json (upstream issue #8).
    /// Nonisolated because `inProgress(root:)` reads it from the command line,
    /// where there is no main actor to be on.
    nonisolated private static let manifestFile = ".recording.json"

    // Track-liveness watchdog. Both .caf files grow continuously while their
    // capture is healthy; a track whose file freezes mid-session (a call app
    // reconfiguring the input device, a died tap — anything) is a recording
    // silently going wrong, and the user should hear about it now, not after
    // the meeting (2026.07.28: a 19min call yielded a 1.7s mic track with no
    // visible symptom until the transcript came out one-sided).
    private var watchdog: Timer?
    private var trackSize: [String: Int64] = [:]
    private var trackLastGrew: [String: Date] = [:]
    private var trackStalled: Set<String> = []
    /// Tracks that stalled at any point, recorded in meta.json so a one-sided
    /// transcript can be explained afterwards rather than puzzled over.
    private var trackEverStalled: Set<String> = []
    /// The tracks that have stalled at some point, for meta.json and tests.
    var stalledTracks: Set<String> { trackEverStalled }
    private static let watchdogInterval: TimeInterval = 15
    private static let stallThreshold: TimeInterval = 45

    /// Bundle-id families the system tap is following. Starts as whatever
    /// held the mic when recording began and grows if another call app joins
    /// mid-session — clicking a Zoom link from a browser call, say.
    private var tapFamilies: [String]
    private var farEndWarningShown = false

    /// Total time spent paused, so meta.json can say how much of the session
    /// is deliberate silence.
    private var pausedFor: TimeInterval = 0
    private var pausedSince: Date?

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, plus the
    /// meeting title when we know it, suffixed on collision) without starting
    /// capture yet. The timestamp stays the prefix so folders keep sorting
    /// chronologically — the transcription queue relies on that.
    init(
        root: URL,
        context: MeetingContext = .empty,
        trigger: Trigger = .manual,
        mic: MicTrackRecorder? = nil,
        system: SystemTrackRecorder? = nil,
        writeFile: @escaping FileWriter = RecordingSession.durableWrite
    ) throws {
        self.context = context
        self.trigger = trigger
        self.tapFamilies = context.appFamilies
        // Built here rather than as default arguments: a default argument is
        // evaluated in the caller's isolation, and these are only ever made
        // for the session that owns them.
        self.mic = mic ?? MicRecorder()
        self.system = system ?? SystemAudioRecorder()
        self.writeFile = writeFile

        var base = Self.folderFormat.string(from: startedAt)
        if let suffix = context.folderSuffix {
            base += " " + suffix
        }
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    ///
    /// A start that fails takes its folder with it. Nothing in it is worth
    /// keeping — at most a few milliseconds of system audio — and a folder
    /// with no meta.json is invisible to every list, so it would never be
    /// transcribed or tidied; an auto-start retrying against a refusal used
    /// to leave one behind per attempt.
    func start(systemAudioScope: String = Config.systemAudioScope()) throws {
        // Point the tap at the call app when we know it. Everything else the
        // Mac plays — music, notifications, the video you open afterwards —
        // then stays out of both the transcript and the auto-record loop's
        // idea of whether the far end is still talking.
        let scope: SystemAudioRecorder.Scope =
            (systemAudioScope == "app" && !tapFamilies.isEmpty)
                ? .apps(tapFamilies)
                : .everything
        // The marker must precede capture. A kill after either recorder starts
        // must leave enough information for crash recovery to adopt the audio.
        writeManifest()
        do {
            try system.start(writingTo: dir.appendingPathComponent("system.caf"), scope: scope)
        } catch {
            abandonFolder()
            throw StartFailure.systemAudio(error)
        }
        do {
            // The mic track follows the same call the tap does: the microphone
            // that app is listening to is the one being spoken into, and it is
            // not always the system default.
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"), callApps: tapFamilies)
        } catch {
            system.stop()
            abandonFolder()
            throw StartFailure.microphone(error)
        }
        Analytics.track(.recordingStarted, [.trigger: .text(trigger.rawValue)])
        let watchdog = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            // Same idiom as AppController's elapsed-time ticker: the timer
            // fires on the main run loop, so promote that to the type system
            // rather than capturing non-Sendable state across a boundary.
            MainActor.assumeIsolated { self?.checkTrackLiveness() }
        }
        // Common modes, like the auto-record timer: in the default mode alone
        // an open menu or a window being dragged holds the tick back, and the
        // tick is what follows the microphone and notices a stalled track.
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    /// Remove the folder of a session that never started. Only ever called
    /// before either track is running, so there is nothing in it that a
    /// meeting depends on.
    private func abandonFolder() {
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            // Second best: at least do not leave a manifest claiming a
            // recording, which crash recovery would then try to adopt.
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(Self.manifestFile))
        }
    }

    /// Stop both tracks, write meta.json, and drop the in-progress manifest.
    ///
    /// Returns whether meta.json was written — whether the folder is now a
    /// finished session, rather than one that the next launch's recovery
    /// has to finish from its manifest. Only a finished one can be queued.
    @discardableResult
    func stop(reason: String = "manual") -> Bool {
        watchdog?.invalidate()
        watchdog = nil
        if pausedSince != nil { resume() }
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": Self.startOffsets(
                mic: mic.firstBufferAt, system: system.firstBufferAt),
            "trigger": trigger.rawValue,
            "stop_reason": reason,
            "system_audio": {
                if case .apps(let families) = system.scope {
                    return "app: " + families.sorted().joined(separator: ", ")
                }
                return "all"
            }(),
        ]
        if let title { meta["title"] = title }
        meta.merge(context.metaFields) { current, _ in current }
        if pausedFor > 0 { meta["paused_seconds"] = Int(pausedFor) }
        if !trackEverStalled.isEmpty { meta["stalled_tracks"] = trackEverStalled.sorted() }
        meta["mic_capture"] = mic.capture.meta
        // Every route change the mic track survived: headphones connecting,
        // AirPods leaving an ear, a call app taking the device. Each one is a
        // seam in the track, and a transcript that goes strange after one is
        // explained here rather than guessed at.
        let restarts = mic.restarts
        if !restarts.isEmpty {
            meta["mic_restarts"] = restarts.map { $0.meta(iso: iso) }
        }

        // meta.json and the manifest are the only two things that make this
        // folder a session, so one of them has to be on disk at every moment.
        // The manifest goes only once meta.json is known to be there; a disk
        // that refuses meta.json keeps the manifest, rewritten without our
        // pid so that the next recovery adopts it instead of taking it for a
        // recording still in progress.
        let finished: Bool
        do {
            try writeFile(Self.json(meta), dir.appendingPathComponent("meta.json"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.manifestFile))
            finished = true
        } catch {
            Self.reportMetaFailure(error, in: dir)
            writeManifest(stopped: meta)
            finished = false
        }

        let length = ended.timeIntervalSince(startedAt)
        let systemHeardSomething = system.lastSoundAt != nil
        Analytics.track(.recordingFinished, [
            .trigger: .text(trigger.rawValue),
            .durationBucket: Analytics.durationBucket(seconds: length),
            .liveUsed: .flag(liveAudioEverInstalled),
            .systemAudio: .flag(systemHeardSomething),
        ])
        if !systemHeardSomething, length > 60 {
            Analytics.track(.systemTrackSilent, [
                .durationBucket: Analytics.durationBucket(seconds: length),
            ])
        }
        return finished
    }

    /// Attach/detach optional live-ASR consumers without touching the durable
    /// recording. Installing midway through a meeting deliberately receives
    /// only new buffers, so enabling live text never performs catch-up work.
    func installLiveAudioSinks(mic micSink: LiveAudioSink?, system systemSink: LiveAudioSink?) {
        if micSink != nil || systemSink != nil { liveAudioEverInstalled = true }
        mic.installLiveAudioSink(micSink)
        system.installLiveAudioSink(systemSink)
    }

    private var liveAudioEverInstalled = false

    // MARK: - pause

    private(set) var isPaused = false

    /// Keep capturing but write silence to both tracks. Capture is deliberately
    /// not torn down: rebuilding the tap and the engine mid-session is the
    /// riskiest thing this program does, and a pause is exactly when you don't
    /// want to gamble on it coming back. Writing silence also keeps both files
    /// growing, which keeps the stall watchdog honest and keeps every timestamp
    /// after the pause aligned to the wall clock.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pausedSince = Date()
        mic.setLiveAudioPaused(true)
        system.setLiveAudioPaused(true)
        mic.isMuted = true
        system.isMuted = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let since = pausedSince { pausedFor += Date().timeIntervalSince(since) }
        pausedSince = nil
        mic.isMuted = false
        system.isMuted = false
        mic.setLiveAudioPaused(false)
        system.setLiveAudioPaused(false)
    }

    // MARK: - levels

    /// When either track last carried something audible. The auto-record
    /// controller's silence backstop reads this; nil means nothing has been
    /// heard on that track yet.
    var lastMicSoundAt: Date? { mic.lastSoundAt }
    var lastSystemSoundAt: Date? { system.lastSoundAt }
    var microphoneSignal: Float? { mic.signalLevel }
    var systemSignal: Float? { system.signalLevel }

    /// False when either track's sample format defeated the level meter. The
    /// silence backstop must then stand down — "can't measure" and "silent"
    /// look identical, and only one of them should end a meeting.
    var levelsMeasurable: Bool { mic.levelMeasurable && system.levelMeasurable }

    // MARK: - discarding

    /// Delete the whole session folder. Used for automatic recordings that
    /// turned out to be too short to be a meeting — a mic that opened for a
    /// few seconds is a false positive, and keeping it means the recordings
    /// folder fills with rubbish nobody deletes.
    func discard() {
        Analytics.track(.recordingDiscarded, [
            .trigger: .text(trigger.rawValue),
            .durationBucket: Analytics.durationBucket(
                seconds: Date().timeIntervalSince(startedAt)),
        ])
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - what is being recorded right now

    /// Every session folder that still holds an in-progress manifest, with the
    /// pid that wrote it and the moment it started.
    ///
    /// This is the only answer on disk to "is something being recorded right
    /// now". `meta.json` is written when a recording stops, so anything that
    /// reads it — `amanu sessions`, the transcription queue — can only ever
    /// say no, which is the wrong answer in exactly the case that matters
    /// (.issues/005).
    nonisolated static func inProgress(root: URL) -> [RecordingInProgress] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        let iso = ISO8601DateFormatter()
        var found: [RecordingInProgress] = []

        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = dir.appendingPathComponent(manifestFile)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            // A manifest beside a meta.json is litter from a stop that failed
            // to delete it, not a recording: that session has ended, and
            // recoverInterrupted tidies the file away on the next launch.
            guard !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else {
                continue
            }
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = manifest["pid"] as? Int32
            else { continue }

            // The same liveness test recovery uses, and the same caveat: a
            // recycled PID could fool it. Here the cost is warning about a
            // recording that has already ended, which is again the safe
            // direction to be wrong in.
            found.append(RecordingInProgress(
                dir: dir,
                pid: pid,
                started: (manifest["started"] as? String).flatMap { iso.date(from: $0) },
                ownerIsAlive: processIsAlive(pid)
            ))
        }
        return found
    }

    // MARK: - crash recovery

    /// Adopt sessions left behind by a crash: a folder with an in-progress
    /// manifest, no meta.json, and no live process owning it. Writes the
    /// meta.json the clean-stop path would have written, so the normal
    /// transcription queue picks the session up as if it had ended politely.
    ///
    /// Returns the recovered folders, oldest first.
    @discardableResult
    static func recoverInterrupted(
        root: URL, writeFile: FileWriter = RecordingSession.durableWrite
    ) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        let fm = FileManager.default
        var recovered: [URL] = []

        for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = dir.appendingPathComponent(manifestFile)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            guard !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else {
                // Clean stop that failed to delete its manifest — tidy up.
                try? fm.removeItem(at: manifestURL)
                continue
            }
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                FileHandle.standardError.write(Data(
                    "unreadable manifest in \(dir.lastPathComponent) — leaving it alone\n".utf8
                ))
                continue
            }

            // A live owner means a second amanu is recording into this folder
            // right now. Leave it strictly alone. (A recycled PID could fool
            // this; the cost is deferring recovery to the next launch, which
            // is the safe direction to be wrong in.) A manifest without a pid
            // is one a stop left behind when meta.json would not write.
            if let pid = manifest["pid"] as? Int32, processIsAlive(pid) { continue }

            // Something has to be in the tracks, or there's nothing to recover.
            let files = (manifest["files"] as? [String: String]) ?? [:]
            let sizes = files.values.compactMap { name -> Int64? in
                (try? fm.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path
                ))?[.size] as? Int64
            }
            guard let largest = sizes.max(), largest > 0 else {
                // Its owner is gone, so nothing will ever be written here.
                // Leaving the manifest meant saying "has no audio" on every
                // launch and `amanu doctor` warning about an unrecovered
                // recording forever.
                FileHandle.standardError.write(Data(
                    "interrupted session \(dir.lastPathComponent) has no audio — removing it\n".utf8
                ))
                removeEmptySession(dir)
                continue
            }

            let iso = ISO8601DateFormatter()
            let started = (manifest["started"] as? String).flatMap { iso.date(from: $0) }
            // The last write to either track is when the recording really
            // ended — the process died without telling anyone.
            let ended = files.values.compactMap { name -> Date? in
                (try? fm.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path
                ))?[.modificationDate] as? Date
            }.max() ?? Date()

            var meta: [String: Any] = [
                "started": iso.string(from: started ?? ended),
                "ended": iso.string(from: ended),
                "duration_seconds": Int(ended.timeIntervalSince(started ?? ended)),
                "files": files,
                "start_offset_ms": manifest["start_offset_ms"] as? [String: Int] ?? [:],
                "trigger": manifest["trigger"] as? String ?? Trigger.manual.rawValue,
                "stop_reason": "recovered-after-crash",
                "recovered": true,
            ]
            if let title = manifest["title"] as? String { meta["title"] = title }
            if let app = manifest["app"] as? String { meta["app"] = app }
            if let calendar = manifest["calendar"] as? [String: Any] {
                meta["calendar"] = calendar
            }
            // A stop that could not write meta.json kept what it would have
            // written here, and that is a better account than one rebuilt
            // from file dates: it knows why the recording ended and what the
            // microphone did.
            if let stopped = manifest["meta"] as? [String: Any] {
                meta = stopped
                meta["recovered"] = true
            }

            // The manifest goes only once meta.json is on disk. Without either
            // the folder is not a session to anything that lists them, and
            // the recording disappears with its audio still in it.
            do {
                try writeFile(json(meta), dir.appendingPathComponent("meta.json"))
            } catch {
                reportMetaFailure(error, in: dir)
                continue
            }
            try? fm.removeItem(at: manifestURL)
            Analytics.track(.sessionInterrupted, [
                .trigger: .text(manifest["trigger"] as? String ?? Trigger.manual.rawValue),
                .durationBucket: Analytics.durationBucket(
                    seconds: ended.timeIntervalSince(started ?? ended)),
            ])
            recovered.append(dir)
        }

        if !recovered.isEmpty {
            FileHandle.standardError.write(Data(
                "recovered \(recovered.count) interrupted recording(s)\n".utf8
            ))
            notifyUser(
                title: localised(
                    "amanu — interrupted recording recovered",
                    "amanu — прерванная запись восстановлена"),
                body: recovered.map { $0.lastPathComponent }.joined(separator: ", ")
            )
        }
        return recovered
    }

    /// Whether the process that wrote a manifest is still running.
    ///
    /// `EPERM` is an answer, not a failure: it means the process exists and
    /// belongs to someone we may not signal. Reading it as "gone" would let
    /// recovery adopt a recording still being written, and the queue then
    /// transcribe it and settle its audio out from under the recorder.
    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Remove a session whose owner is gone and that holds no audio. The
    /// manifest always goes; the folder goes too when nothing in it has a
    /// byte in it, so an empty folder does not outlive its manifest.
    private static func removeEmptySession(_ dir: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        let onlyEmpty = contents.allSatisfy { item in
            if item.lastPathComponent == manifestFile { return true }
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 1) == 0
        }
        if onlyEmpty {
            try? fm.removeItem(at: dir)
        } else {
            try? fm.removeItem(at: dir.appendingPathComponent(manifestFile))
        }
    }

    // MARK: -

    /// Record who owns this folder and what it is, so a crash is recoverable.
    /// Written once at start and refreshed when the tracks' first buffers have
    /// landed (the offsets aren't known before then).
    ///
    /// `stopped` is the meta.json a stop could not write. It is kept here
    /// instead, without our pid, so that the folder stays a session and the
    /// next recovery adopts it rather than mistaking it for one in progress.
    private func writeManifest(stopped: [String: Any]? = nil) {
        let iso = ISO8601DateFormatter()
        var manifest: [String: Any] = [
            "started": iso.string(from: startedAt),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "trigger": trigger.rawValue,
        ]
        if let stopped {
            manifest["meta"] = stopped
        } else {
            manifest["pid"] = ProcessInfo.processInfo.processIdentifier
        }
        if let title { manifest["title"] = title }
        manifest.merge(context.metaFields) { current, _ in current }
        if mic.firstBufferAt != nil || system.firstBufferAt != nil {
            manifest["start_offset_ms"] = Self.startOffsets(
                mic: mic.firstBufferAt, system: system.firstBufferAt)
        }
        do {
            try writeFile(Self.json(manifest), dir.appendingPathComponent(Self.manifestFile))
        } catch {
            FileHandle.standardError.write(Data(
                "couldn't write the recording manifest in \(dir.lastPathComponent): \(error)\n".utf8
            ))
        }
    }

    /// How far each track's first buffer lags the earlier of the two, so the
    /// transcripts share one clock.
    ///
    /// A track that never delivered a buffer takes no part in choosing the
    /// reference and is put at zero: it has no audio for an offset to move,
    /// and counting it from when the session was created would push the
    /// track that did record later than it happened.
    nonisolated static func startOffsets(mic: Date?, system: Date?) -> [String: Int] {
        guard let earliest = [mic, system].compactMap({ $0 }).min() else {
            return ["mic": 0, "system": 0]
        }
        func offset(_ start: Date?) -> Int {
            start.map { Int($0.timeIntervalSince(earliest) * 1000) } ?? 0
        }
        return ["mic": offset(mic), "system": offset(system)]
    }

    nonisolated static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Write `data` so that once this returns it is on the disk, not in a
    /// cache: a temporary beside the destination, flushed, then renamed over
    /// it. The manifest is removed on the strength of this returning, so
    /// "the write call did not complain" is not enough.
    nonisolated static func durableWrite(_ data: Data, _ url: URL) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Say so when meta.json cannot be written. The session is not lost —
    /// the manifest stays behind for recovery — but it will not be
    /// transcribed until that happens, and a full disk is worth hearing about
    /// while there is still a meeting to save.
    nonisolated static func reportMetaFailure(_ error: Error, in dir: URL) {
        FileHandle.standardError.write(Data(
            "couldn't write meta.json in \(dir.lastPathComponent): \(error)\n".utf8
        ))
        notifyUser(
            title: localised(
                "amanu: couldn't save the recording's details",
                "amanu: не удалось сохранить сведения о записи"),
            body: localised(
                "The audio is kept and will be picked up again at the next launch. Is the disk full?",
                "Звук сохранён и будет подхвачен при следующем запуске. Не заполнен ли диск?"),
            opening: dir
        )
    }

    /// Compare each track file's size against the last poll. Growth clears any
    /// stall state (and announces recovery); a freeze past the threshold
    /// notifies once per stall episode, so a track that dies, recovers, and
    /// dies again alerts both times without spamming in between.
    ///
    /// A track that is not there at all is the worst stall of all, not a
    /// reason to look away. The mic recorder deletes its file when voice
    /// processing turns out silent at the start and rebuilds it raw; if that
    /// rebuild fails there is no file, and skipping missing files meant the
    /// one banner that could have said so never came.
    func checkTrackLiveness(now: Date = Date()) {
        var offsetsPending = false

        for name in ["mic", "system"] {
            let path = dir.appendingPathComponent("\(name).caf").path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64

            if let size, size != trackSize[name] {
                trackSize[name] = size
                trackLastGrew[name] = now
                if trackStalled.remove(name) != nil {
                    notifyUser(
                        title: localised(
                            "amanu: \(name) track recovered",
                            "amanu: дорожка \(name) снова пишется"),
                        body: localised(
                            "\(name) audio is being written again.",
                            "Звук \(name) снова записывается."),
                        opening: dir
                    )
                }
                continue
            }
            // Counted from the start for a track that has never grown, so a
            // file that never appeared stalls on the same clock as one that
            // stopped.
            let last = trackLastGrew[name] ?? startedAt
            guard !trackStalled.contains(name),
                  now.timeIntervalSince(last) >= Self.stallThreshold
            else { continue }
            trackStalled.insert(name)
            trackEverStalled.insert(name)
            let silentFor = Int(now.timeIntervalSince(last))
            notifyUser(
                title: localised(
                    "amanu: \(name) track stalled", "amanu: дорожка \(name) встала"),
                body: size == nil
                    ? localised(
                        "There is no \(name) track being written — the recording may be incomplete.",
                        "Дорожка \(name) не записывается — запись может быть неполной.")
                    : localised(
                        "No \(name) audio written for \(silentFor)s — the recording may be incomplete.",
                        "Звук \(name) не пишется уже \(silentFor) с — запись может быть неполной."),
                opening: dir
            )
        }

        followCallApp(now: now)

        // Which microphone is the right one is not settled once at the start.
        // The call app can move to another device without anything
        // system-wide changing, and a default that changes under a running
        // engine is silent in every other way, so the question is asked again
        // on every tick. Both are cheap; being on the wrong microphone for an
        // hour is not.
        mic.follow(callApps: tapFamilies)
        mic.checkRoute()

        // Refresh the manifest once both first buffers have landed, so a crash
        // recovers with the same clock alignment a clean stop would have had.
        if !manifestOffsetsWritten, mic.firstBufferAt != nil, system.firstBufferAt != nil {
            manifestOffsetsWritten = true
            offsetsPending = true
        }
        if offsetsPending { writeManifest() }
    }

    private var manifestOffsetsWritten = false

    /// Keep the tap pointed at the call as its processes come and go, and
    /// notice if that leaves us recording silence.
    private func followCallApp(now: Date) {
        if case .apps = system.scope {
            let settings = Config.autoRecord()
            let mic = MicActivityMonitor.check(
                callApps: settings.callApps, ignoring: settings.ignoreApps
            )
            // A second call app joining the session counts too: clicking a Zoom
            // link during a browser call is an ordinary thing to do, and the
            // far-end track shouldn't go quiet because of it.
            let families = Array(Set(tapFamilies).union(mic.families)).sorted()
            if families != tapFamilies { tapFamilies = families }
            system.refresh(scope: .apps(tapFamilies))
        }

        // The failure mode of a scoped tap is silence with no error: a tap on
        // the wrong process delivers zeroed buffers for as long as you like.
        // If you have been talking and nothing has come back for five minutes,
        // say so — once — rather than letting an hour go by.
        guard !farEndWarningShown else { return }
        guard Self.shouldWarnAboutFarEndSilence(
            scope: system.scope,
            recordingStartedAt: startedAt,
            micLastSoundAt: mic.lastSoundAt,
            systemLastSoundAt: system.lastSoundAt,
            now: now
        ) else { return }
        let farEndSilentFor = now.timeIntervalSince(system.lastSoundAt ?? startedAt)
        farEndWarningShown = true
        let detail: (String, String)
        if case .apps = system.scope {
            detail = (
                "Recording only \(tapFamilies.joined(separator: ", ")) and it has been silent for \(Int(farEndSilentFor / 60)) min. Set system_audio to \"all\" if this is wrong.",
                "Пишется только \(tapFamilies.joined(separator: ", ")), и там тихо уже \(Int(farEndSilentFor / 60)) мин. Если это неверно, поставьте system_audio в \"all\"."
            )
        } else {
            detail = (
                "Nothing has been heard on the system track for \(Int(farEndSilentFor / 60)) min. Check the call output and System Audio Recording permission.",
                "На системной дорожке ничего не слышно уже \(Int(farEndSilentFor / 60)) мин. Проверьте выход звука звонка и разрешение на запись системного аудио."
            )
        }
        notifyUser(
            title: localised(
                "amanu: nothing from the far end", "amanu: от дальней стороны ничего нет"),
            body: localised(detail.0, detail.1)
        )
    }

    nonisolated static func shouldWarnAboutFarEndSilence(
        scope: SystemAudioRecorder.Scope,
        recordingStartedAt: Date,
        micLastSoundAt: Date?,
        systemLastSoundAt: Date?,
        now: Date
    ) -> Bool {
        _ = scope // Both app-scoped and global taps can silently lose permission.
        let youSpokeRecently = micLastSoundAt.map { now.timeIntervalSince($0) < 120 } ?? false
        let farEndSilentFor = now.timeIntervalSince(systemLastSoundAt ?? recordingStartedAt)
        return youSpokeRecently && farEndSilentFor > 300
    }
}
