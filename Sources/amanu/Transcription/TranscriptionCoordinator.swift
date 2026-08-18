import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
///
/// Per-track engines (parakeet) get mic.caf → "me" and system.caf → "them";
/// each track's segments are shifted by its start offset and merged by
/// timestamp. Diarizing engines (assemblyai) instead get a single mixed.m4a
/// laid out on that same shared clock, and their anonymous speaker labels are
/// mapped back onto me/them from the source tracks' energy.
///
/// Either way the result is transcript.json (canonical) plus transcript.md
/// (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    /// The single mixed-down file diarizing engines transcribe. Derived from
    /// the tracks, so it's regenerated whenever it's missing.
    private static let mixedFile = "mixed.m4a"

    /// How many times a session may fail before the queue stops offering it.
    /// The queue lives in the filesystem and is rescanned at every launch, so
    /// without a limit a session that cannot be transcribed is retried for
    /// ever — and with a cloud engine, re-uploaded and re-charged every time.
    private static let maxAttempts = 3

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    && !Self.hasGivenUp(on: $0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                do {
                    try await transcribe(dir)
                } catch {
                    // The network can go away between the reachability probe
                    // and the upload. One retry on the local engine, so a
                    // dropped connection costs minutes rather than the
                    // transcript.
                    guard Config.transcriptionEngine() == "auto",
                          engineIsCloud(), Self.looksLikeNetworkTrouble(error)
                    else { throw error }
                    log(dir, "cloud transcription failed (\(error)) — retrying locally")
                    await engine?.release()
                    engine = ParakeetEngine()
                    try await engine?.prepare()
                    try await transcribe(dir)
                }
                notifyUser(title: "amanu — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                recordFailure(error, for: dir)
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    /// Count a failure against the session, and retire it once retrying has
    /// stopped being reasonable — either because the error can't be fixed by
    /// repeating it, or because we've repeated it enough.
    ///
    /// A retired session keeps its audio and gets it compressed: there will
    /// never be a transcript, so holding a gigabyte an hour of PCM against a
    /// future attempt is pure waste. Delete `transcription_failed` from
    /// meta.json to offer it to the queue again.
    private func engineIsCloud() -> Bool {
        engine?.input == .mixed
    }

    /// Network-shaped failures, the ones a local engine can rescue. A bad key
    /// or a rejected file is not one of them — retrying locally would still be
    /// right, but silently swapping engines for every failure hides real
    /// problems.
    private static func looksLikeNetworkTrouble(_ error: Error) -> Bool {
        let urlErrorCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        ]
        if let urlError = error as? URLError { return urlErrorCodes.contains(urlError.code) }
        return "\(error)".contains("offline") || "\(error)".contains("timed out")
    }

    private func recordFailure(_ error: Error, for dir: URL) {
        let permanent = (error as? TranscriptionFailure)?.isPermanent ?? false
        let attempts =
            (SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int ?? 0) + 1
        var fields: [String: Any?] = [SessionState.Key.transcriptionAttempts: attempts]

        if permanent || attempts >= Self.maxAttempts {
            fields[SessionState.Key.transcriptionFailed] = "\(error)"
            SessionState.update(dir, with: fields)
            log(dir, permanent
                ? "giving up: \(error) — retrying cannot change this"
                : "giving up after \(attempts) attempts")
            notifyUser(
                title: "amanu — transcription gave up",
                body: "\(dir.lastPathComponent) — audio kept, see transcribe.log"
            )
            TrackCompressor.compress(sessionDir: dir)
        } else {
            SessionState.update(dir, with: fields)
            notifyUser(
                title: "amanu — transcription failed",
                body: "\(dir.lastPathComponent) — see transcribe.log"
            )
        }
    }

    private static func hasGivenUp(on dir: URL) -> Bool {
        SessionState.value(dir, SessionState.Key.transcriptionFailed) != nil
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment]
        switch engine.input {
        case .perTrack:
            merged = try await transcribePerTrack(dir, meta: meta, engine: engine)
            merged.sort { $0.start_ms < $1.start_ms }
            // Only the per-track path can double-transcribe the far end: it
            // reads both tracks, and a raw mic recording through speakers has
            // their voice on it too. A diarizing engine sees the mix once, so
            // there's no duplicate for a filter to find.
            if Config.transcriptEchoFilter() {
                let before = merged.count
                merged = EchoFilter.dropEchoes(merged)
                if merged.count != before {
                    log(dir, "echo filter dropped \(before - merged.count) "
                        + "mic segment(s) duplicating system audio")
                }
            }
        case .mixed:
            merged = try await transcribeMixed(dir, meta: meta, engine: engine)
            merged.sort { $0.start_ms < $1.start_ms }
        }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")

        // After the transcript, never instead of it: transcript.json is the
        // completion marker, so anything that runs before it risks retiring a
        // session that has no transcript. Naming and summarizing both just log
        // when they can't run, and are picked up again by a later sweep.
        SessionScript.install(in: dir)
        await PostProcessor.finish(dir)

        // Last of all: the audio was recorded uncompressed so it would survive
        // a crash, and that only needs to hold until the transcript exists.
        TrackCompressor.compress(sessionDir: dir)
    }

    /// One pass per track, speaker taken from the track itself.
    private func transcribePerTrack(
        _ dir: URL,
        meta: SessionMeta,
        engine: TranscriptionEngine
    ) async throws -> [Transcript.Segment] {
        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        return merged
    }

    /// One pass over mixed.m4a, speaker taken from the engine's diarization
    /// and then renamed to me/them by matching each utterance back against the
    /// source tracks. The mix already carries the start offsets, so its
    /// timestamps need no shifting.
    private func transcribeMixed(
        _ dir: URL,
        meta: SessionMeta,
        engine: TranscriptionEngine
    ) async throws -> [Transcript.Segment] {
        let mixed = dir.appendingPathComponent(Self.mixedFile)
        if !FileManager.default.fileExists(atPath: mixed.path) {
            log(dir, "mixing tracks → \(Self.mixedFile)")
            try await AudioMixer.mix(
                meta.tracks.map {
                    AudioMixer.Track(
                        url: dir.appendingPathComponent($0.file),
                        offset: TimeInterval($0.offsetMs) / 1000
                    )
                },
                to: mixed
            )
        }

        log(dir, "transcribing \(Self.mixedFile) (\(engine.name))")
        let segments = try await engine.transcribe(mixed)

        let names = meta.track(for: "me").flatMap { mic in
            meta.track(for: "them").flatMap { system in
                SpeakerAttribution.resolve(
                    segments: segments,
                    mic: dir.appendingPathComponent(mic.file),
                    micOffset: TimeInterval(mic.offsetMs) / 1000,
                    system: dir.appendingPathComponent(system.file),
                    systemOffset: TimeInterval(system.offsetMs) / 1000
                )
            }
        }
        if let names {
            let counts = names.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            log(dir, "speakers: " + counts.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", "))
        } else {
            log(dir, "couldn't attribute speakers to tracks — keeping diarization labels")
        }

        return segments.enumerated().map { index, segment in
            Transcript.Segment(
                speaker: names?[index] ?? segment.speaker ?? "speaker",
                start_ms: Int(segment.start * 1000),
                end_ms: Int(segment.end * 1000),
                text: segment.text
            )
        }
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        let engine: TranscriptionEngine
        switch configured {
        case "assemblyai":
            engine = try AssemblyAIEngine()
        case "parakeet":
            engine = ParakeetEngine()
        case "auto":
            engine = await Self.bestAvailableEngine()
        default:
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — choosing automatically\n".utf8
            ))
            engine = await Self.bestAvailableEngine()
        }
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Cloud when it's actually usable, local otherwise. Checked at the moment
    /// there is work rather than at launch, because the answer changes: the
    /// laptop that recorded a meeting on a train is transcribing it on a train.
    private static func bestAvailableEngine() async -> TranscriptionEngine {
        guard Config.assemblyAIKey() != nil else { return ParakeetEngine() }
        guard await assemblyAIReachable() else {
            FileHandle.standardError.write(Data(
                "assemblyai unreachable — transcribing locally with parakeet\n".utf8
            ))
            return ParakeetEngine()
        }
        return (try? AssemblyAIEngine()) ?? ParakeetEngine()
    }

    /// A short, cheap "is the API there" probe. Any HTTP answer counts,
    /// including an unauthorized one: the question is whether the network is
    /// up, not whether the key is good.
    private static func assemblyAIReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "https://api.assemblyai.com/v2/transcript")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        // The session it was fired for is the only sensible place to stand.
        task.currentDirectoryURL = dir
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        appendSessionLog(message, to: dir)
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]
    /// What the session knows about the meeting. All of it goes into the
    /// summary prompt: knowing the subject, who was in the room and which app
    /// the call ran in measurably improves what comes back — not least because
    /// a summarizer given names can use them instead of "me" and "them".
    let title: String?
    let attendees: [String]
    let app: String?

    func track(for speaker: String) -> Track? {
        tracks.first { $0.speaker == speaker }
    }

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        let calendar = json["calendar"] as? [String: Any]
        return SessionMeta(
            tracks: tracks,
            title: (json["title"] as? String) ?? (calendar?["title"] as? String),
            attendees: calendar?["attendees"] as? [String] ?? [],
            app: json["app"] as? String
        )
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Render transcript.md, then write transcript.json as the completion
    /// marker. Both writes are atomic (temp file + rename), and writing the
    /// JSON last is what makes the ordering matter: resumePending treats its
    /// presence as "done", so writing it first meant a failed markdown write
    /// retired the session permanently with half its artifacts.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(self)

        try writeMarkdown(to: dir, names: SpeakerNames.read(from: dir))
        try json
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    /// Render transcript.md against whatever names are known, which is what
    /// makes naming re-runnable: the JSON keeps the recognizer's own labels
    /// for ever, and the readable file is regenerated from it whenever a name
    /// is learned or corrected.
    func writeMarkdown(to dir: URL, names: SpeakerNames?) throws {
        try Data(rendered(title: dir.lastPathComponent, names: names).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    /// A copy with each label replaced by its known name, for readers that
    /// take the speaker straight off the segment — the summarizer, mainly,
    /// which writes "Фёдор will send the contract" only if that is what it was
    /// given to read.
    func named(with names: SpeakerNames?) -> Transcript {
        guard let names else { return self }
        return Transcript(
            engine: engine,
            model: model,
            created_at: created_at,
            segments: segments.map {
                Segment(
                    speaker: names.name(for: $0.speaker),
                    start_ms: $0.start_ms,
                    end_ms: $0.end_ms,
                    text: $0.text
                )
            }
        )
    }

    func rendered(title: String, names: SpeakerNames?) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        // A roster only earns its place when it says something the body
        // doesn't: which label a name stands for.
        let named = (names?.speakers ?? [:]).compactMap { label, entry in
            entry.name.map { "\(label) → \($0)" }
        }.sorted()
        if !named.isEmpty {
            lines.append("speakers: " + named.joined(separator: ", "))
        }
        lines.append("")
        for seg in segments {
            let who = names?.name(for: seg.speaker) ?? seg.speaker
            lines.append("**[\(Self.clock(seg.start_ms))] \(who):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
