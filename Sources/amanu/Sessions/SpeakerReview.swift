import CryptoKit
import Foundation
import os

/// A short, optional human step owned by the desktop UI. The transcript remains
/// complete while review is open, and its per-session claim protects it from CLI
/// and sweeps without holding up recognition of another recording.
enum SpeakerReview {
    typealias Handler = @Sendable (URL) -> Void
    private static let registry = HandlerRegistry()
    @TaskLocal static var scopedHandler: Handler?
    @TaskLocal static var usesInstalledHandler = true

    static func installHandler(_ value: Handler?) {
        registry.install(value)
    }

    /// The desktop controller retains the token for exactly its own lifetime.
    /// Releasing an older controller cannot unregister a newer controller's UI.
    static func registerHandler(_ value: @escaping Handler) -> HandlerToken {
        registry.register(value)
    }

    final class HandlerToken: Sendable {
        private let id: UUID
        private let registry: HandlerRegistry

        fileprivate init(id: UUID, registry: HandlerRegistry) {
            self.id = id
            self.registry = registry
        }

        deinit { registry.unregister(id) }
    }

    /// Separate instances make ownership tests independent of the running app.
    final class HandlerRegistry: Sendable {
        private struct Entry: Sendable {
            let id: UUID
            let handler: Handler
        }
        private let entry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

        var current: Handler? { entry.withLock { $0?.handler } }

        func register(_ handler: @escaping Handler) -> HandlerToken {
            let id = UUID()
            entry.withLock { $0 = Entry(id: id, handler: handler) }
            return HandlerToken(id: id, registry: self)
        }

        fileprivate func install(_ handler: Handler?) {
            entry.withLock { current in
                current = handler.map { Entry(id: UUID(), handler: $0) }
            }
        }

        fileprivate func unregister(_ id: UUID) {
            entry.withLock { current in
                if current?.id == id { current = nil }
            }
        }
    }

    private static var offerHandler: Handler? {
        scopedHandler ?? (usesInstalledHandler ? registry.current : nil)
    }

    static func transcriptID(_ dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func record(_ dir: URL) -> [String: Any]? {
        guard let record = SessionState.value(dir, SessionState.Key.speakerReview) as? [String: Any],
              record["transcript"] as? String == transcriptID(dir) else { return nil }
        return record
    }

    static func isPending(_ dir: URL) -> Bool {
        guard let state = record(dir)?["state"] as? String else { return false }
        return state == "ready" || state == "reviewing"
    }

    static func hasDecision(_ dir: URL) -> Bool {
        record(dir)?["state"] as? String == "complete"
    }

    /// Called only after a new successful ASR, while its transcription claim is held.
    /// Capability comes from the engine; two diarized voices may still be named
    /// `me/them` after channel attribution, so label spelling is not a capability.
    static func recordTranscript(_ dir: URL, supportsDiarization: Bool) throws {
        try SessionState.amend(dir, with: [
            SessionState.Key.speakerReview: try pendingRecord(dir, supportsDiarization: supportsDiarization),
        ])
    }

    /// The review record for the transcript now at the root, or nil when none is
    /// owed. Separate from writing it so `TranscriptVersions.commit` can publish
    /// it in the same meta.json write that publishes the transcript: written
    /// afterwards, a failure left a new transcript with no review and a
    /// recorded transcription failure.
    static func pendingRecord(_ dir: URL, supportsDiarization: Bool) throws -> [String: Any]? {
        let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let transcript = try JSONDecoder().decode(Transcript.self, from: data)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let labels = Set(transcript.segments.map(\.speaker))
        guard supportsDiarization && labels.count > 1 else { return nil }
        return [
            "transcript": id, "state": "ready", "owner_pid": ProcessInfo.processInfo.processIdentifier,
            "interactive": offerHandler != nil,
        ]
    }

    /// Covers the brief handoff between the ASR claim and the review claim.
    /// A separate CLI must not turn that live desktop offer into a headless skip.
    static func isOwnedByOtherLiveUI(_ dir: URL) -> Bool {
        guard isPending(dir), let current = record(dir), current["interactive"] as? Bool == true,
              let pid = current["owner_pid"] as? Int32,
              pid != ProcessInfo.processInfo.processIdentifier else { return false }
        return RecordingSession.processIsAlive(pid)
    }

    /// Called with a finish claim. A recovered step and a headless invocation skip
    /// review; an offer is persisted before it reaches the UI and retains the claim.
    static func offerOrSkip(_ dir: URL, summaryEnabled: Bool) throws -> Bool {
        guard let current = record(dir), isPending(dir) else { return false }
        try suggestLocalOwner(dir)
        if current["state"] as? String == "ready", summaryEnabled,
           current["owner_pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier,
           let offer = offerHandler {
            try SessionClaim.changeStage(dir, to: .review)
            var updated = current
            updated["state"] = "reviewing"
            try SessionState.amend(dir, with: [SessionState.Key.speakerReview: updated])
            offer(dir)
            return true
        }
        try resolve(dir)
        return false
    }

    /// Both buttons use the names already entered; skip never clears them.
    /// The caller continues with PostProcessor.finish after this returns.
    static func complete(_ dir: URL) throws {
        try Config.requireReadable()
        try SessionLock.withLock(dir) {
            guard isPending(dir) else { return }
            guard let owner = SessionClaim.holder(dir), owner.stage == SessionClaim.Stage.review.rawValue,
                  owner.pid == ProcessInfo.processInfo.processIdentifier else {
                throw SessionClaim.Busy(session: dir.lastPathComponent, holder: SessionClaim.holder(dir))
            }
            defer { if hasDecision(dir) { SessionClaim.release(dir) } }
            try resolve(dir)
        }
    }

    private static func resolve(_ dir: URL) throws {
        guard var updated = record(dir) else { return }
        updated["state"] = "complete"
        updated["audio_pending"] = true
        updated.removeValue(forKey: "owner_pid")
        // A valid decision must reach disk before its claim and source audio go.
        try SessionState.amend(dir, with: [
            SessionState.Key.speakerReview: updated,
            SessionState.Key.summaryUpdateRequested: true,
        ])
        try settleAudioIfNeeded(dir)
    }

    /// A local suggestion is useful before review, without asking another model
    /// or pretending every voice sharing the microphone belongs to its owner.
    private static func suggestLocalOwner(_ dir: URL) throws {
        try SessionLock.withLock(dir) {
            guard let transcript = PostProcessor.readTranscript(dir),
                  transcript.segments.contains(where: { $0.speaker == "me" }),
                  let owner = SpeakerNamer.ownerName() else { return }
            var names = SpeakerNames.read(from: dir) ?? SpeakerNames()
            guard names.speakers["me"]?.source != .manual,
                  names.speakers["me"]?.name == nil else { return }
            names.speakers["me"] = owner
            try names.write(to: dir)
            try transcript.writeMarkdown(to: dir, names: names)
            let revision = SessionState.value(dir, SessionState.Key.speakerNamesRevision) as? Int ?? 0
            try SessionState.amend(dir, with: [SessionState.Key.speakerNamesRevision: revision + 1])
        }
    }

    static func needsAudioSettlement(_ dir: URL) -> Bool {
        record(dir)?["audio_pending"] as? Bool == true
    }

    static func settleAudioIfNeeded(_ dir: URL) throws {
        guard needsAudioSettlement(dir), var updated = record(dir) else { return }
        TrackCompressor.settle(sessionDir: dir)
        updated.removeValue(forKey: "audio_pending")
        try SessionState.amend(dir, with: [SessionState.Key.speakerReview: updated])
    }

    struct AudioSample {
        struct Source {
            let file: URL
            let start: TimeInterval
            /// Delay on the meeting clock when a track begins after this clip.
            let delay: TimeInterval
        }
        let file: URL
        let start: TimeInterval
        let end: TimeInterval
        let title: String
        let sources: [Source]
        let duration: TimeInterval

        init(file: URL, start: TimeInterval, end: TimeInterval, title: String,
             sources: [Source]? = nil, duration: TimeInterval? = nil) {
            self.file = file
            self.start = start
            self.end = end
            self.title = title
            self.sources = sources ?? [Source(file: file, start: start, delay: 0)]
            self.duration = duration ?? end - start
        }
    }

    static func audioSample(for sample: SessionInventory.Sample, in session: URL) -> AudioSample? {
        audioSamples(for: sample, in: session).first
    }

    static func audioSamples(for sample: SessionInventory.Sample, in session: URL) -> [AudioSample] {
        guard let meta = try? SessionMeta.read(from: session) else { return [] }
        let shared = meta.tracks.count > 1 && Set(meta.tracks.map(\.file)).count == 1
        let exists = { (track: SessionMeta.Track) in
            FileManager.default.fileExists(atPath: session.appendingPathComponent(track.file).path)
        }
        var ranges: [(Int?, Int?, String)] = [
            (sample.firstStartMs, sample.firstEndMs, localised("First turn", "Первая реплика")),
        ]
        if sample.longest != sample.first {
            ranges.append((sample.longestStartMs, sample.longestEndMs,
                           localised("Longest turn", "Самая длинная реплика")))
        }
        func clips(on track: SessionMeta.Track) -> [AudioSample] {
            let file = session.appendingPathComponent(track.file)
            return ranges.compactMap { first, last, title in
                guard let first, let last else { return nil }
                let start = max(0, Double(first - track.offsetMs) / 1000)
                let end = max(start, min(Double(last - track.offsetMs) / 1000, start + 8))
                return end > start ? AudioSample(file: file, start: start, end: end, title: title) : nil
            }
        }
        let track: SessionMeta.Track?
        if meta.isSingleSource || shared { track = meta.tracks.first }
        else if sample.label == "me" || sample.label.hasPrefix("me ") { track = meta.track(for: "me") }
        else if sample.label == "them" || sample.label.hasPrefix("them ") { track = meta.track(for: "them") }
        else {
            // A diarized label with no side is what attribution leaves when it
            // could not place a voice. Once the tracks are archived together
            // that is still playable; while they are separate — compression
            // failed, or has not happened yet — the mix the engine heard is
            // the honest source. If it is absent, play both original tracks
            // together on their recorded clock rather than guessing a side.
            let mix = SessionMeta.Track(
                file: TranscriptionInputs.mixedFile, speaker: "speaker", offsetMs: 0, channel: nil)
            let present = meta.tracks.filter(exists)
            if exists(mix) { track = mix }
            else {
                return ranges.compactMap { first, last, title in
                    guard let first, let last, last > first else { return nil }
                    let duration = min(Double(last - first) / 1000, 8)
                    let sources = present.compactMap { candidate -> AudioSample.Source? in
                        let delay = max(0, Double(candidate.offsetMs - first) / 1000)
                        guard delay < duration else { return nil }
                        return AudioSample.Source(
                            file: session.appendingPathComponent(candidate.file),
                            start: max(0, Double(first - candidate.offsetMs) / 1000), delay: delay)
                    }
                    guard let primary = sources.first else { return nil }
                    return AudioSample(file: primary.file, start: primary.start,
                                       end: primary.start + duration, title: title,
                                       sources: sources, duration: duration)
                }
            }
        }
        guard let track, exists(track) else { return [] }
        return clips(on: track)
    }

}
