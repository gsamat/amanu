import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — speech models do better on clean single-source
/// audio, and two tracks give free two-party diarization.
@MainActor
final class RecordingSession {
    /// What started this session. Manual recordings are never stopped or
    /// discarded automatically: if you pressed the button, you meant it.
    enum Trigger: String {
        case manual
        case micActivity = "mic-activity"
        case calendar
    }

    let dir: URL
    let startedAt = Date()
    let title: String?
    let trigger: Trigger

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    /// Written at start, removed on clean stop. Its presence in a folder with
    /// no meta.json is what tells the next launch "this session was
    /// interrupted" — without it, a crash leaves perfectly good CAF files that
    /// nothing ever looks at again, because the transcription queue only
    /// considers folders that have a meta.json (upstream issue #8).
    private static let manifestFile = ".recording.json"

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
    private static let watchdogInterval: TimeInterval = 15
    private static let stallThreshold: TimeInterval = 45

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
    init(root: URL, title: String? = nil, trigger: Trigger = .manual) throws {
        self.title = title
        self.trigger = trigger

        var base = Self.folderFormat.string(from: startedAt)
        if let title, !title.isEmpty {
            base += " " + Self.sanitize(title)
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
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
        writeManifest()
        watchdog = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval, repeats: true
        ) { [weak self] _ in
            // Same idiom as AppController's elapsed-time ticker: the timer
            // fires on the main run loop, so promote that to the type system
            // rather than capturing non-Sendable state across a boundary.
            MainActor.assumeIsolated { self?.checkTrackLiveness() }
        }
    }

    /// Stop both tracks, write meta.json, and drop the in-progress manifest.
    func stop(reason: String = "manual") {
        watchdog?.invalidate()
        watchdog = nil
        if pausedSince != nil { resume() }
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            "trigger": trigger.rawValue,
            "stop_reason": reason,
        ]
        if let title { meta["title"] = title }
        if pausedFor > 0 { meta["paused_seconds"] = Int(pausedFor) }
        if !trackEverStalled.isEmpty { meta["stalled_tracks"] = trackEverStalled.sorted() }

        Self.write(meta: meta, to: dir)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.manifestFile))
    }

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
    }

    // MARK: - levels

    /// When either track last carried something audible. The auto-record
    /// controller's silence backstop reads this; nil means nothing has been
    /// heard on that track yet.
    var lastMicSoundAt: Date? { mic.lastSoundAt }
    var lastSystemSoundAt: Date? { system.lastSoundAt }

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
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - crash recovery

    /// Adopt sessions left behind by a crash: a folder with an in-progress
    /// manifest, no meta.json, and no live process owning it. Writes the
    /// meta.json the clean-stop path would have written, so the normal
    /// transcription queue picks the session up as if it had ended politely.
    ///
    /// Returns the recovered folders, oldest first.
    @discardableResult
    static func recoverInterrupted(root: URL) -> [URL] {
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

            // A live owner means a second quill is recording into this folder
            // right now. Leave it strictly alone. (A recycled PID could fool
            // this; the cost is deferring recovery to the next launch, which
            // is the safe direction to be wrong in.)
            if let pid = manifest["pid"] as? Int32, kill(pid, 0) == 0 { continue }

            // Something has to be in the tracks, or there's nothing to recover.
            let files = (manifest["files"] as? [String: String]) ?? [:]
            let sizes = files.values.compactMap { name -> Int64? in
                (try? fm.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path
                ))?[.size] as? Int64
            }
            guard let largest = sizes.max(), largest > 0 else {
                FileHandle.standardError.write(Data(
                    "interrupted session \(dir.lastPathComponent) has no audio — skipping\n".utf8
                ))
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

            write(meta: meta, to: dir)
            try? fm.removeItem(at: manifestURL)
            recovered.append(dir)
        }

        if !recovered.isEmpty {
            FileHandle.standardError.write(Data(
                "recovered \(recovered.count) interrupted recording(s)\n".utf8
            ))
            notifyUser(
                title: "quill — interrupted recording recovered",
                body: recovered.map { $0.lastPathComponent }.joined(separator: ", ")
            )
        }
        return recovered
    }

    // MARK: -

    /// Record who owns this folder and what it is, so a crash is recoverable.
    /// Written once at start and refreshed when the tracks' first buffers have
    /// landed (the offsets aren't known before then).
    private func writeManifest() {
        let iso = ISO8601DateFormatter()
        var manifest: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started": iso.string(from: startedAt),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "trigger": trigger.rawValue,
        ]
        if let title { manifest["title"] = title }
        if let micStart = mic.firstBufferAt, let systemStart = system.firstBufferAt {
            let earliest = min(micStart, systemStart)
            manifest["start_offset_ms"] = [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent(Self.manifestFile), options: .atomic)
        }
    }

    private static func write(meta: [String: Any], to dir: URL) {
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    /// Folder-safe version of a meeting title: no path separators, no colons
    /// (Finder shows them as slashes), and short enough to read in a list.
    private static func sanitize(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.count > 60 ? String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
                                  : cleaned
    }

    /// Compare each track file's size against the last poll. Growth clears any
    /// stall state (and announces recovery); a freeze past the threshold
    /// notifies once per stall episode, so a track that dies, recovers, and
    /// dies again alerts both times without spamming in between.
    private func checkTrackLiveness() {
        let now = Date()
        var offsetsPending = false

        for name in ["mic", "system"] {
            let path = dir.appendingPathComponent("\(name).caf").path
            guard let size = (try? FileManager.default
                .attributesOfItem(atPath: path))?[.size] as? Int64 else { continue }

            if size != trackSize[name] {
                trackSize[name] = size
                trackLastGrew[name] = now
                if trackStalled.remove(name) != nil {
                    notifyUser(
                        title: "quill: \(name) track recovered",
                        body: "\(name) audio is being written again."
                    )
                }
            } else if let last = trackLastGrew[name], !trackStalled.contains(name),
                      now.timeIntervalSince(last) >= Self.stallThreshold {
                trackStalled.insert(name)
                trackEverStalled.insert(name)
                notifyUser(
                    title: "quill: \(name) track stalled",
                    body: "No \(name) audio written for \(Int(now.timeIntervalSince(last)))s"
                        + " — the recording may be incomplete."
                )
            }
        }

        // Refresh the manifest once both first buffers have landed, so a crash
        // recovers with the same clock alignment a clean stop would have had.
        if !manifestOffsetsWritten, mic.firstBufferAt != nil, system.firstBufferAt != nil {
            manifestOffsetsWritten = true
            offsetsPending = true
        }
        if offsetsPending { writeManifest() }
    }

    private var manifestOffsetsWritten = false
}
