import CoreML
// FluidAudio ships `OfflineDiarizerManager` as a plain class with no `Sendable`
// annotation, and its `process` is nonisolated, so Swift 6 cannot see that
// handing the instance out of this actor is safe and reports the send as a
// possible data race. It is safe because the manager is only ever touched from
// this actor and `voices` will not start a second pass while one is in flight.
// `AsrManager` needs no such note because it is an actor.
@preconcurrency import FluidAudio
import Foundation

/// Local speaker diarization of the far side, via FluidAudio's offline VBx
/// pipeline — pyannote-style powerset segmentation, WeSpeaker embeddings, and
/// PLDA/VBx clustering, run on the Neural Engine.
///
/// This is the one local model amanu runs that does not transcribe. It exists
/// because a per-track engine is handed `system.caf` alone and can only ever
/// answer "them": three people sharing the far end's room mic come back as one
/// speaker. A diarizer over that same track — after the fact, on the same
/// post-hoc batch clock as everything else — is what tells them apart, and
/// `DiarizationAlignment` puts the answer onto the ASR segments.
///
/// Not a `TranscriptionEngine`: it produces no text and is not chosen per
/// session. `TranscriptionCoordinator` holds one for the length of a drain,
/// beside the engine, and releases it when the queue empties.
///
/// The offline pipeline is chosen over the faster Sortformer because this is
/// batch work over whole meetings, where Sortformer's four-speaker cap and
/// short-clip accuracy are the wrong trade. FluidAudio's own docs put the
/// offline stack at macOS 14 / iOS 17, which is where amanu already starts.
actor DiarizationEngine {
    private var manager: OfflineDiarizerManager?

    /// Set while a diarization pass is in flight. `process` is nonisolated, so
    /// awaiting it suspends this actor and lets a second caller in, and the
    /// manager cannot run twice at once. This is what makes the send above
    /// safe rather than merely silenced.
    private var isProcessing = false

    /// Recorded as provenance the way an engine's `model` is. A fixed pipeline
    /// rather than a versioned checkpoint, so there is no setting behind it.
    nonisolated let model = "speaker-diarization-coreml (offline VBx)"

    /// Where FluidAudio keeps the offline diarizer's compiled models. Shared
    /// with the doctor check and the storage window, so the files they look
    /// for cannot drift from the ones `prepare` would fetch.
    static func modelsDirectory() -> URL {
        OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    /// The model files that are not on this Mac yet, in a stable order. Empty
    /// means the pipeline is ready to run without a download.
    static func missingModels() -> [String] {
        let directory = modelsDirectory()
        return ModelNames.OfflineDiarizer.requiredModels
            .filter {
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent($0).path)
            }
            .sorted()
    }

    /// Download and compile the models if they are not already here. Safe to
    /// call more than once: the second call is a no-op, and a first call that
    /// throws leaves nothing half-initialized to trip over.
    func prepare() async throws {
        guard manager == nil else { return }
        let manager = OfflineDiarizerManager(config: .default)
        let configuration = MLModelConfiguration()
        // The offline pipeline's own default is `.all`, which also puts the
        // graph on the GPU. Pinning it to the Neural Engine and CPU keeps
        // Core ML off the GPU path — the one FluidAudio has had graph-compile
        // crashes in — and the model is built for the ANE anyway, so the
        // accuracy is the same and only the place it runs moves.
        configuration.computeUnits = .cpuAndNeuralEngine
        try await manager.prepareModels(configuration: configuration)
        self.manager = manager
    }

    /// Who spoke when in `audio`, on the file's own clock. Never throws: a
    /// diarization that fails costs a transcript its "them A" and leaves it a
    /// flat "them", which is what it would have been without this pass at all
    /// — and never costs it the transcript.
    func voices(in audio: URL) async -> [DiarizationAlignment.Voice] {
        guard let manager, !isProcessing else { return [] }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let result = try await manager.process(audio)
            return result.segments.map {
                DiarizationAlignment.Voice(
                    id: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds))
            }
        } catch {
            FileHandle.standardError.write(Data(
                ("warning: local diarization of \(audio.lastPathComponent) failed — "
                    + "\(error); the far side stays \"them\"\n").utf8))
            return []
        }
    }

    func release() async {
        manager = nil
    }
}

/// Puts an anonymous voice label from a diarizer onto ASR segments by time
/// overlap, and turns it into the same "them A" / "them B" vocabulary the
/// cloud engines' channel-qualified labels reach.
///
/// Pure, and deliberately free of FluidAudio types: the part worth testing is
/// the arithmetic that decides which voice a sentence belongs to, and that
/// needs no model to answer.
enum DiarizationAlignment {
    /// One stretch of one voice, as the diarizer reported it, on the same
    /// clock as the segments it is aligned to.
    struct Voice: Equatable, Sendable {
        /// The diarizer's own cluster id — "S1", "S2", … Nothing outside this
        /// file sees it: it is only a key for grouping segments, and the
        /// letters in the transcript are assigned by first appearance.
        let id: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// The voice a segment belongs to: the one it overlaps most.
    ///
    /// Overlap rather than the midpoint or the start, because an ASR segment
    /// is a sentence and a diarizer segment is a stretch of one voice, and the
    /// two are cut by different rules — a segment routinely straddles a voice
    /// change. The voice it spends most of itself inside is the honest answer.
    /// nil when no voice overlaps at all: the diarizer heard nobody where the
    /// engine heard words, which happens on music, noise, and very short
    /// utterances, and is not a speaker.
    static func voice(of segment: TranscriptSegment, among voices: [Voice]) -> String? {
        var best: String?
        var bestOverlap: TimeInterval = 0
        // Earliest first, and a strict `>` below, so a tie goes to the voice
        // that started first rather than to whichever the diarizer happened to
        // emit first — the same answer on a rerun. The id is part of the
        // ordering because `sorted` is not stable: two voices sharing a start
        // would otherwise be separated by an unspecified order.
        for voice in voices.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let overlap = min(segment.end, voice.end) - max(segment.start, voice.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = voice.id
            }
        }
        return best
    }

    /// Labels for one side's segments, in order: `side` alone where the
    /// diarizer heard a single voice (or none), `side A` / `side B` / … where
    /// it heard several.
    ///
    /// Letters are assigned in order of first appearance, so the same meeting
    /// gets the same letters on a rerun — the reason `SpeakerAttribution`
    /// sorts its suffixes too. A side holding one voice keeps the plain label:
    /// "them" beats "them A" when there is only one them, which is the rule
    /// `MultichannelSpeakerLabels` already applies to the cloud's labels, and
    /// the reason the suffix is only built once there are two voices to tell
    /// apart.
    static func labels(
        for segments: [TranscriptSegment], voices: [Voice], side: String
    ) -> [String] {
        guard !voices.isEmpty else { return segments.map { _ in side } }
        let ordered = voices.sorted { $0.start < $1.start }
        let assigned = segments.map { voice(of: $0, among: ordered) }

        var letters: [String: String] = [:]
        for id in assigned {
            guard let id, letters[id] == nil else { continue }
            letters[id] = SpeakerAttribution.suffix(letters.count)
        }
        guard letters.count > 1 else { return segments.map { _ in side } }

        return assigned.map { id in
            guard let id, let letter = letters[id] else { return side }
            return "\(side) \(letter)"
        }
    }
}
