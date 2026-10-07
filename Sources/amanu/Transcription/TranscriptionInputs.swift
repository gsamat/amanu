import AVFoundation
import Foundation

/// The three ways a session's audio is handed to an engine — one call per
/// track, one aligned stereo file, one mix — each turning what comes back
/// into segments on the session's clock with me/them already decided.
///
/// `audio` is where the tracks are read from, which is not always the session
/// folder: with offline echo cancellation it is a hidden folder of cleaned
/// copies. The log is always the session's own.
struct TranscriptionInputs {
    /// The single mixed-down file used by engines that cannot consume the two
    /// channels directly. Derived from the tracks and regenerated when absent.
    static let mixedFile = "mixed.m4a"
    static let multichannelFile = "multichannel.m4a"
    static let multichannelTemporary = "multichannel.tmp.m4a"

    let session: URL
    let audio: URL
    let meta: SessionMeta
    let engine: TranscriptionEngine
    /// The far side's speaker diarizer, prepared by the coordinator when the
    /// setting is on and this Mac can run the model. nil keeps the flat
    /// "them" — which is what the local engines have always produced, and
    /// what a single far-end voice should stay.
    var diarizer: DiarizationEngine?

    func segments() async throws -> [Transcript.Segment] {
        switch engine.input {
        case .perTrack: return try await perTrack()
        case .multichannel: return try await multichannel()
        case .mixed: return try await mixed()
        }
    }

    private func log(_ message: String) {
        appendSessionLog(message, to: session)
    }

    /// Whether both tracks live in one stereo archive, one channel each —
    /// which is what a settled session is.
    private var sharedArchive: Bool {
        meta.tracks.count == 2
            && meta.tracks.allSatisfy { $0.file == meta.tracks[0].file && $0.channel != nil }
    }

    /// One aligned stereo input. One-based channel labels from the engine
    /// carry the side directly (`1A` is mic, `2A` is system), so this path does
    /// no envelope comparison and remains correct when the raw mic contains a
    /// quieter acoustic copy of the far end.
    func multichannel() async throws -> [Transcript.Segment] {
        let dir = audio
        // An imported file has no "my side" and "their side" — it is one
        // ordinary mixed recording. Hand its mono source to a diarizing engine
        // as-is, and keep the engine's A/B labels rather than interpreting
        // their first character as a channel number.
        if meta.isSingleSource, let source = meta.tracks.first {
            let file = dir.appendingPathComponent(source.file)
            log("transcribing \(source.file) (\(engine.name))")
            return try await engine.transcribe(file).map { segment in
                Transcript.Segment(
                    speaker: segment.speaker ?? "speaker",
                    start_ms: Int(segment.start * 1000),
                    end_ms: Int(segment.end * 1000),
                    text: segment.text)
            }
        }

        let sharedArchive = sharedArchive
        let file = sharedArchive
            ? dir.appendingPathComponent(meta.tracks[0].file)
            : dir.appendingPathComponent(Self.multichannelFile)

        if !sharedArchive && !FileManager.default.fileExists(atPath: file.path) {
            let temporary = dir.appendingPathComponent(Self.multichannelTemporary)
            let mic = meta.track(for: "me").map {
                TrackCompressor.StereoTrack(
                    url: dir.appendingPathComponent($0.file), offsetMs: $0.offsetMs)
            }
            let system = meta.track(for: "them").map {
                TrackCompressor.StereoTrack(
                    url: dir.appendingPathComponent($0.file), offsetMs: $0.offsetMs)
            }
            log("aligning tracks → \(Self.multichannelFile)")
            do {
                try await Task.detached(priority: .utility) {
                    _ = try TrackCompressor.encodeStereo(
                        mic: mic, system: system, to: temporary)
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: temporary, to: file)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }

        log("transcribing \(file.lastPathComponent) (\(engine.name))")
        return MultichannelSpeakerLabels.map(try await engine.transcribe(file))
    }

    /// One pass per track, speaker taken from the track itself.
    func perTrack() async throws -> [Transcript.Segment] {
        let dir = audio
        // A track of its own that is not on disk at all is a silent side as
        // much as an empty one is: the microphone can fall back to raw
        // capture and leave no mic.caf behind, and the mixer and the
        // archiver already read a missing track as silence. Only when no
        // side has any audio is the recording itself gone. A channel of a
        // shared archive is different: the archive missing is the whole
        // recording missing, and says so below.
        let missing = meta.tracks.filter {
            $0.channel == nil
                && !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path)
        }
        let heard = meta.tracks.contains { track in
            let url = dir.appendingPathComponent(track.file)
            return FileManager.default.fileExists(atPath: url.path)
                && (track.channel != nil || !Self.holdsNoAudio(url))
        }
        if let gone = missing.first, !heard {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [
                NSFilePathErrorKey: dir.appendingPathComponent(gone.file).path,
            ])
        }

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let storedAudio = dir.appendingPathComponent(track.file)
            if track.channel == nil, missing.contains(where: { $0.file == track.file }) {
                log("\(track.file) is not in the folder — \(track.speaker) is silent in this "
                    + "recording")
                continue
            }
            guard FileManager.default.fileExists(atPath: storedAudio.path) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: storedAudio.path])
            }
            // The recorders create their files when recording starts, so a
            // side that never delivered a buffer — a system tap that was
            // never granted, a microphone that died at once — leaves a track
            // with a header and no audio. That is a silent side, not a broken
            // recording: the engines call a file with no frames unreadable,
            // and unreadable is permanent, so one empty track used to retire
            // the whole meeting on its first attempt.
            if track.channel == nil, Self.holdsNoAudio(storedAudio) {
                log("\(track.file) holds no audio — \(track.speaker) is silent in this recording")
                continue
            }

            var file = storedAudio
            var temporary: URL?
            if let channel = track.channel {
                let extracted = FileManager.default.temporaryDirectory
                    .appendingPathComponent("amanu-\(UUID().uuidString)-channel-\(channel).m4a")
                do {
                    try await Task.detached(priority: .utility) {
                        try AudioChannelExtractor.extract(
                            channel: channel, from: storedAudio, to: extracted)
                    }.value
                    file = extracted
                    temporary = extracted
                } catch {
                    try? FileManager.default.removeItem(at: extracted)
                    log("could not extract \(track.speaker) channel in \(track.file): \(error)")
                    throw error
                }
            }

            log("transcribing \(track.file)\(track.channel.map { " channel \($0)" } ?? "") "
                + "(\(engine.name))")
            // A failed track must not turn into a successful partial transcript:
            // successful completion allows the original audio to be discarded.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(file)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                log("could not transcribe \(track.file): \(error)")
                throw error
            }
            // The far side, told apart. Run over the very file the engine just
            // read — the extracted channel where there is one — so the
            // diarizer's clock is the ASR clock and the offset below lands on
            // both alike. The microphone is left alone: "me" is already one
            // person, and a diarizer over that track could only split them.
            var labels: [String]?
            if track.speaker == "them", let diarizer {
                let voices = await diarizer.voices(in: file)
                if !voices.isEmpty {
                    labels = DiarizationAlignment.labels(
                        for: segments, voices: voices, side: track.speaker)
                    log("local diarization heard \(Set(voices.map(\.id)).count) "
                        + "voice(s) on \(track.file)")
                }
            }
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.enumerated().map { index, segment in
                Transcript.Segment(
                    speaker: labels?[index] ?? track.speaker,
                    start_ms: Int((segment.start + offset) * 1000),
                    end_ms: Int((segment.end + offset) * 1000),
                    text: segment.text
                )
            }
        }
        return merged
    }

    /// A track that exists but has nothing in it: no bytes at all, or a
    /// header and no frames.
    static func holdsNoAudio(_ url: URL) -> Bool {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if bytes == 0 { return true }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length == 0
    }

    /// One pass over mixed.m4a, speaker taken from the engine's diarization
    /// and then renamed to me/them by matching each utterance back against the
    /// source tracks. The mix already carries the start offsets, so its
    /// timestamps need no shifting.
    func mixed() async throws -> [Transcript.Segment] {
        let dir = audio
        let importedSource = meta.isSingleSource
            ? meta.tracks.first.map { dir.appendingPathComponent($0.file) }
            : nil
        let sharedArchive = sharedArchive
        let mixed = importedSource ?? (sharedArchive
            ? dir.appendingPathComponent(meta.tracks[0].file)
            : dir.appendingPathComponent(Self.mixedFile))
        if importedSource == nil, !sharedArchive,
           !FileManager.default.fileExists(atPath: mixed.path) {
            log("mixing tracks → \(Self.mixedFile)")
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

        log("transcribing \(Self.mixedFile) (\(engine.name))")
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
            log("speakers: " + counts.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }
                .joined(separator: ", "))
        } else {
            log("couldn't attribute speakers to tracks — keeping diarization labels")
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
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
        let channel: Int?
    }

    let tracks: [Track]
    /// What the session knows about the meeting. All of it goes into the
    /// summary prompt: knowing the subject, who was in the room and which app
    /// the call ran in measurably improves what comes back — not least because
    /// a summarizer given names can use them instead of "me" and "them".
    let title: String?
    let attendees: [String]
    let app: String?

    var isSingleSource: Bool {
        tracks.count == 1 && tracks[0].speaker == "speaker"
    }

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
        let channels = json["audio_channels"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(
                file: mic,
                speaker: "me",
                offsetMs: offsets["mic"] ?? 0,
                channel: channels["mic"]))
        }
        if let system = files["system"] {
            tracks.append(Track(
                file: system,
                speaker: "them",
                offsetMs: offsets["system"] ?? 0,
                channel: channels["system"]))
        }
        if let source = files["source"] {
            tracks.append(Track(
                file: source,
                speaker: "speaker",
                offsetMs: offsets["source"] ?? 0,
                channel: channels["source"]))
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
