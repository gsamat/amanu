import AVFoundation
import Foundation

/// Settles a finished session's audio once its transcript exists: either
/// deletes it, or turns the two PCM tracks into one stereo AAC archive and
/// deletes the originals.
///
/// Recording writes uncompressed PCM because that is the only format that
/// survives a hard kill (see AudioFormats), at about a gigabyte an hour across
/// both tracks. That's a fine price for the duration of a meeting and a silly
/// one for an archive, so once the transcript exists — the thing the audio was
/// for — `keep_audio` decides whether it is archived or discarded.
///
/// Order matters and is deliberate: transcript first, then settling. A failed
/// transcription never calls this, so the only copy of a meeting is kept.
enum TrackCompressor {
    /// What becomes of a session's audio once its transcript exists: kept and
    /// compressed, or thrown away — `keep_audio` decides.
    ///
    /// The one caller that must not come through here is the failure path:
    /// a session with no transcript keeps its audio unconditionally, because
    /// that recording is the only copy of the meeting and a later attempt is
    /// all it has.
    static func settle(sessionDir dir: URL) {
        guard DiarizationState.read(dir)?.retainsAudio != true else { return }
        if Config.keepAudio() {
            compress(sessionDir: dir)
        } else {
            discard(sessionDir: dir)
        }
    }

    /// Delete the audio, leaving the transcript, the summary and the record of
    /// what was recorded. meta.json keeps its `files` — it is the session's
    /// account of itself, and "there was a mic track called mic.caf" stays
    /// true after the file goes — and gains `audio_discarded`, which is what
    /// stops the recordings window offering to transcribe it again.
    static func discard(sessionDir dir: URL) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }
        let fm = FileManager.default

        let named = (SessionState.read(dir)?["files"] as? [String: String]).map { Array($0.values) } ?? []
        // Both extensions for every track: a session interrupted between
        // compressing and rewriting meta.json has one of each on disk.
        var candidates = Set<String>()
        for name in named {
            candidates.insert(name)
            let stem = (name as NSString).deletingPathExtension
            candidates.insert("\(stem).caf")
            candidates.insert("\(stem).m4a")
        }
        candidates.insert("mixed.m4a")
        candidates.insert("mixed.tmp.m4a")
        candidates.insert("multichannel.m4a")
        candidates.insert("multichannel.tmp.m4a")
        candidates.insert("audio.m4a")
        candidates.insert("audio.tmp.m4a")
        if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
            candidates.formUnion(entries.filter { $0.hasPrefix("diarization-source-")
                && $0.hasSuffix(".caf") })
        }

        var freed: Int64 = 0
        var removed = 0
        for name in candidates.sorted() {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let bytes = size(of: url)
            do {
                try fm.removeItem(at: url)
                freed += bytes
                removed += 1
            } catch {
                log("couldn't delete \(name): \(error)")
            }
        }

        guard removed > 0 else { return }
        SessionState.update(dir, with: ["audio_discarded": true])
        log("audio discarded — \(mb(freed)) freed (keep_audio is off)")
    }

    /// Align the mic and system tracks on their shared clock, archive them as
    /// the left and right channels of one M4A, then delete what's been
    /// replaced. A missing track becomes a silent channel; an existing track
    /// that cannot be read aborts the operation and remains untouched.
    static func compress(sessionDir dir: URL) {
        func log(_ message: String) { appendSessionLog(message, to: dir) }

        let metaURL = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metaURL),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = meta["files"] as? [String: String]
        else {
            log("compression skipped — can't read meta.json")
            return
        }

        // Imported media has already been normalized to compact AAC, and it
        // deliberately has no invented mic/system sides. Re-encoding it into
        // stereo would both lose quality and manufacture a silent channel.
        if let source = files["source"],
           source.lowercased().hasSuffix(".m4a"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent(source).path) {
            SessionState.update(dir, with: ["compressed": true])
            log("imported audio already archived → \(source)")
            return
        }

        if files["mic"] == "audio.m4a",
           files["system"] == "audio.m4a",
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.m4a").path) {
            // Already archived — but possibly interrupted between rewriting
            // meta.json and deleting the originals, which leaves a gigabyte an
            // hour of PCM that nothing else would ever remove.
            removeLeftovers(in: dir, meta: meta, log: log)
            return
        }

        let offsets = meta["start_offset_ms"] as? [String: Int] ?? [:]
        let archive = dir.appendingPathComponent("audio.m4a")
        let temporary = dir.appendingPathComponent("audio.tmp.m4a")
        let mic = files["mic"].map {
            StereoTrack(url: dir.appendingPathComponent($0), offsetMs: offsets["mic"] ?? 0)
        }
        let system = files["system"].map {
            StereoTrack(url: dir.appendingPathComponent($0), offsetMs: offsets["system"] ?? 0)
        }

        let saved: String
        do {
            saved = try encodeStereo(mic: mic, system: system, to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log("compression failed, keeping the originals: \(error)")
            return
        }

        do {
            try? FileManager.default.removeItem(at: archive)
            try FileManager.default.moveItem(at: temporary, to: archive)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            log("couldn't put audio.m4a in place, keeping the originals: \(error)")
            return
        }

        // Only the keys the archive changes are written, and under the
        // session's lock: encoding takes minutes, and writing back the copy
        // read before it would erase whatever naming or summarizing recorded
        // in meta.json meanwhile.
        //
        // The PCM is deleted only after meta.json points somewhere else, so an
        // interruption at any point leaves a session that still resolves to
        // files that exist.
        do {
            try SessionState.amend(dir, with: [
                "files": ["mic": "audio.m4a", "system": "audio.m4a"],
                // What the archive replaced, so a compression interrupted
                // after this point can finish deleting it on the next pass.
                "archived_from": files,
                "audio_channels": ["mic": 0, "system": 1],
                "recorded_start_offset_ms": meta["start_offset_ms"],
                "start_offset_ms": ["mic": 0, "system": 0],
                "compressed": true,
            ])
        } catch {
            try? FileManager.default.removeItem(at: archive)
            log("couldn't rewrite meta.json (\(error)) — keeping the originals")
            return
        }

        for name in Set(files.values) where name != archive.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        // Derived from the tracks and regenerated on demand; keeping it costs
        // more than the tracks themselves.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("mixed.m4a"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("mixed.tmp.m4a"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("multichannel.m4a"))
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent("multichannel.tmp.m4a"))
        log("archived mic left + system right → audio.m4a (\(saved))")
    }

    /// Finish a compression that was interrupted after meta.json had been
    /// pointed at the archive: delete the originals it replaced, once the
    /// archive has been opened and found to hold two channels of audio.
    /// Sessions archived before `archived_from` existed name no originals, and
    /// theirs were always `mic.caf` and `system.caf`.
    private static func removeLeftovers(
        in dir: URL, meta: [String: Any], log: (String) -> Void
    ) {
        let fm = FileManager.default
        let originals = (meta["archived_from"] as? [String: String]).map { Array($0.values) }
            ?? ["mic.caf", "system.caf"]
        let leftovers = Set(originals + ["mixed.m4a", "mixed.tmp.m4a", "multichannel.m4a",
                                         "multichannel.tmp.m4a", "audio.tmp.m4a"])
            .filter { $0 != "audio.m4a" && fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard !leftovers.isEmpty else { return }
        guard let archive = try? AVAudioFile(forReading: dir.appendingPathComponent("audio.m4a")),
              archive.processingFormat.channelCount == 2, archive.length > 0
        else {
            log("audio.m4a can't be read — keeping \(leftovers.sorted().joined(separator: ", "))")
            return
        }
        var freed: Int64 = 0
        for name in leftovers.sorted() {
            let url = dir.appendingPathComponent(name)
            let bytes = size(of: url)
            if (try? fm.removeItem(at: url)) != nil { freed += bytes }
        }
        log("finished an interrupted compression — \(mb(freed)) of originals removed")
    }

    // MARK: -

    enum CompressionError: Error, CustomStringConvertible {
        case unreadable(URL)
        case tooShort(source: Int64, encoded: Int64)
        case noUsableTracks

        var description: String {
            switch self {
            case .unreadable(let url): return "can't read \(url.lastPathComponent)"
            case .tooShort(let source, let encoded):
                return "encoded \(encoded) of \(source) frames"
            case .noUsableTracks: return "no readable audio tracks"
            }
        }
    }

    struct StereoTrack: Sendable {
        let url: URL
        let offsetMs: Int
    }

    /// Stream two independently recorded tracks into a stereo AAC file. This
    /// never holds more than a few seconds in memory, even for a long meeting.
    ///
    /// Each track is mixed down to mono for its channel — the system track is
    /// stereo — and any failure to read one throws, so the caller keeps the
    /// originals rather than archiving silence in place of what it could not
    /// read. A track that is missing, or holds no frames, becomes a silent
    /// channel: there is nothing in it to lose.
    static func encodeStereo(
        mic: StereoTrack?,
        system: StereoTrack?,
        to destination: URL
    ) throws -> String {
        let fm = FileManager.default

        func probe(_ track: StereoTrack?) throws -> AudioTrackReader? {
            guard let track, fm.fileExists(atPath: track.url.path) else { return nil }
            do {
                return try AudioTrackReader(url: track.url)
            } catch AudioTrackReader.ReadError.empty {
                return nil
            } catch {
                throw CompressionError.unreadable(track.url)
            }
        }

        let rates = [try probe(mic), try probe(system)].compactMap { $0?.sourceRate }
        guard let rate = rates.max() else { throw CompressionError.noUsableTracks }
        guard let stereo = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 2,
            interleaved: false
        ) else { throw CompressionError.noUsableTracks }

        func reader(_ track: StereoTrack?) throws -> AudioTrackReader? {
            guard try probe(track) != nil, let track else { return nil }
            return try AudioTrackReader(
                url: track.url, rate: rate, offset: Double(track.offsetMs) / 1000)
        }
        let micReader = try reader(mic)
        let systemReader = try reader(system)
        let readers = [micReader, systemReader].compactMap { $0 }
        let totalFrames = readers.map { $0.start + $0.length }.max()!
        let blockFrames = AVAudioFrameCount(rate)
        try? fm.removeItem(at: destination)

        func writeArchive() throws {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: rate < 32_000 ? 64_000 : 128_000,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: blockFrames)
            else { throw CompressionError.noUsableTracks }

            var position: AVAudioFramePosition = 0
            while position < totalFrames {
                let count = AVAudioFrameCount(min(
                    AVAudioFramePosition(blockFrames), totalFrames - position))
                buffer.frameLength = count
                buffer.floatChannelData![0].update(repeating: 0, count: Int(count))
                buffer.floatChannelData![1].update(repeating: 0, count: Int(count))
                _ = try micReader?.read(
                    into: buffer.floatChannelData![0], frames: count, at: position)
                _ = try systemReader?.read(
                    into: buffer.floatChannelData![1], frames: count, at: position)
                try output.write(from: buffer)
                position += AVAudioFramePosition(count)
            }
        }
        try writeArchive()

        let encoded = try AVAudioFile(forReading: destination)
        guard encoded.processingFormat.channelCount == 2,
              Double(encoded.length) >= Double(totalFrames) * 0.99
        else {
            throw CompressionError.tooShort(source: totalFrames, encoded: encoded.length)
        }

        let before = readers.reduce(Int64(0)) { $0 + size(of: $1.url) }
        return "\(mb(before)) → \(mb(size(of: destination)))"
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
