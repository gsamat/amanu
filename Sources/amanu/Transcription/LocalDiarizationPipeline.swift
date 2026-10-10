import AVFoundation
import CryptoKit
import FluidAudio
import Foundation

/// Batch attribution on the same durable 16 kHz clock used for recognition.
enum LocalDiarizationPipeline {
    enum Resolution: String, Codable, Sendable { case word, turn }

    enum IntervalKind: String, Codable, Sendable { case single, ambiguous, uncovered }

    struct ProcessingInterval: Codable, Sendable {
        let startSample: Int64
        let endSample: Int64
        let kind: IntervalKind
        let speakerID: String?
    }

    struct TurnASRCache: Codable, Sendable {
        let turnFingerprint: String
        let segments: [TranscriptSegment]
    }

    struct Result: Codable, Sendable {
        let segments: [Transcript.Segment]
        let rawTurns: [SpeakerTurn]
        let rejectedTurnCount: Int
        /// Full-track word ASR when available, otherwise the turn ASR.
        let asr: [TranscriptSegment]
        let assignments: [DiarizationAlignment.Assignment]
        let intervals: [ProcessingInterval]
        let resolution: Resolution
        let sourceFingerprint: String
        let modelFingerprint: String
        let optionsFingerprint: String
        let asrOptionsFingerprint: String
        let turnASR: TurnASRCache?

        var turnFingerprint: String? { turnASR?.turnFingerprint }
    }

    enum PipelineError: Error {
        case disabled
        case invalidSource
        case invalidFingerprint
        case invalidASR
    }

    private actor ASRPreparation {
        let callback: (@Sendable () async throws -> Void)?
        private var prepared = false

        init(_ callback: (@Sendable () async throws -> Void)?) { self.callback = callback }

        func beforeTranscribe() async throws {
            guard !prepared, let callback else { return }
            try await callback()
            prepared = true
        }
    }

    static func run(
        source: DiarizationAudioSource.Prepared,
        engine: any TranscriptionEngine,
        runtime: any LocalDiarizationRuntime,
        settings: DiarizationSettings,
        cachedASR: [TranscriptSegment]? = nil,
        cachedTurnASR: TurnASRCache? = nil,
        prepareASR: (@Sendable () async throws -> Void)? = nil,
        modelFingerprint: String,
        optionsFingerprint: String,
        asrOptionsFingerprint: String
    ) async throws -> Result {
        guard settings.enabled else { throw PipelineError.disabled }
        guard !modelFingerprint.isEmpty, !optionsFingerprint.isEmpty,
              !asrOptionsFingerprint.isEmpty else { throw PipelineError.invalidFingerprint }
        let asrPreparation = ASRPreparation(prepareASR)
        try DiarizationAudioSource.verify(source)
        try Task.checkCancellation()
        let decodedTurns: [SpeakerTurn]
        var digitallySilent = false
        do {
            decodedTurns = try await runtime.diarize(source.url)
        } catch LocalDiarizationRuntimeError.noSpeechDetected {
            guard cachedASR?.contains(where: hasRecognizedText) != true,
                  cachedTurnASR?.segments.contains(where: hasRecognizedText) != true,
                  try DiarizationAudioSource.isDigitallySilent(source)
            else { throw LocalDiarizationRuntimeError.noSpeechDetected }
            decodedTurns = []
            digitallySilent = true
        }
        try Task.checkCancellation()
        let turns = decodedTurns.filter {
            !$0.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.start < $0.end
                && $0.end <= source.duration + 1.0 / 16_000
        }
        let rejectedTurnCount = decodedTurns.count - turns.count
        let prefix = source.trackID == "source" || source.trackID == "speaker"
            ? "speaker" : "them"

        if engine.name != "gigaam" {
            let fullASR: [TranscriptSegment]
            if digitallySilent {
                fullASR = []
            } else if let cachedASR {
                fullASR = cachedASR
            } else {
                try await asrPreparation.beforeTranscribe()
                fullASR = try await engine.transcribe(source.url)
            }
            try Task.checkCancellation()
            do {
                let aligned = try DiarizationAlignment.align(
                    segments: fullASR, turns: turns, duration: source.duration,
                    labelPrefix: prefix)
                return Result(
                    segments: aligned.segments, rawTurns: turns,
                    rejectedTurnCount: rejectedTurnCount, asr: fullASR,
                    assignments: aligned.assignments, intervals: [], resolution: .word,
                    sourceFingerprint: source.fingerprint, modelFingerprint: modelFingerprint,
                    optionsFingerprint: optionsFingerprint,
                    asrOptionsFingerprint: asrOptionsFingerprint, turnASR: nil)
            } catch DiarizationAlignment.AlignmentError.missingWordTiming {
                // Redecode disjoint turns; the old full-track text is replaced.
            } catch DiarizationAlignment.AlignmentError.invalidWordTiming {
                // Native timestamps cannot safely assign a whole text block.
            }
            let turn = try await turnPath(
                source: source, turns: turns, engine: engine, prefix: prefix,
                cached: cachedTurnASR, asrOptionsFingerprint: asrOptionsFingerprint,
                asrPreparation: asrPreparation)
            return Result(
                segments: turn.segments, rawTurns: turns,
                rejectedTurnCount: rejectedTurnCount, asr: fullASR,
                assignments: [], intervals: turn.intervals, resolution: .turn,
                sourceFingerprint: source.fingerprint, modelFingerprint: modelFingerprint,
                optionsFingerprint: optionsFingerprint,
                asrOptionsFingerprint: asrOptionsFingerprint, turnASR: turn.cache)
        }

        let turn = try await turnPath(
            source: source, turns: turns, engine: engine, prefix: prefix,
            cached: cachedTurnASR, asrOptionsFingerprint: asrOptionsFingerprint,
            asrPreparation: asrPreparation)
        return Result(
            segments: turn.segments, rawTurns: turns,
            rejectedTurnCount: rejectedTurnCount, asr: turn.cache.segments,
            assignments: [], intervals: turn.intervals, resolution: .turn,
            sourceFingerprint: source.fingerprint, modelFingerprint: modelFingerprint,
            optionsFingerprint: optionsFingerprint,
            asrOptionsFingerprint: asrOptionsFingerprint, turnASR: turn.cache)
    }

    private static func hasRecognizedText(_ segment: TranscriptSegment) -> Bool {
        !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || segment.words?.contains(where: {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) == true
    }

    private struct TurnPath {
        let segments: [Transcript.Segment]
        let intervals: [ProcessingInterval]
        let cache: TurnASRCache
    }

    private static func turnPath(
        source: DiarizationAudioSource.Prepared,
        turns: [SpeakerTurn],
        engine: any TranscriptionEngine,
        prefix: String,
        cached: TurnASRCache?,
        asrOptionsFingerprint: String,
        asrPreparation: ASRPreparation
    ) async throws -> TurnPath {
        let intervals = partition(turns: turns, sampleCount: source.sampleCount)
        let fingerprint = turnFingerprint(
            source: source, intervals: intervals, engine: engine,
            asrOptionsFingerprint: asrOptionsFingerprint)
        let turnASR: [TranscriptSegment]
        if let cached, cached.turnFingerprint == fingerprint,
           validTurnCache(cached.segments, intervals: intervals, duration: source.duration) {
            turnASR = cached.segments
        } else {
            var recognized: [TranscriptSegment] = []
            for interval in intervals {
                try Task.checkCancellation()
                recognized += try await transcribe(
                    interval: interval, source: source, engine: engine,
                    asrPreparation: asrPreparation)
            }
            turnASR = recognized
        }
        try Task.checkCancellation()

        var ids: [String] = []
        var seen = Set<String>()
        for interval in intervals where interval.kind == .single {
            if let id = interval.speakerID, seen.insert(id).inserted { ids.append(id) }
        }
        let labels = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, ids.count == 1 ? prefix : "\(prefix) \(suffix(index))")
        })
        let segments = turnASR.map { segment in
            let endMs = max(1, Int((segment.end * 1000).rounded()))
            return Transcript.Segment(
                speaker: segment.speaker.flatMap { labels[$0] } ?? "\(prefix) ?",
                start_ms: min(Int((segment.start * 1000).rounded()), endMs - 1),
                end_ms: endMs,
                text: segment.text)
        }
        return TurnPath(
            segments: segments, intervals: intervals,
            cache: TurnASRCache(turnFingerprint: fingerprint, segments: turnASR))
    }

    private static func suffix(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : String(index + 1)
    }

    private static func validCached(_ segment: TranscriptSegment, duration: Double) -> Bool {
        segment.start.isFinite && segment.end.isFinite
            && segment.start >= 0 && segment.start < segment.end
            && segment.start < duration
            && segment.end <= duration + 1.0 / 16_000
    }

    private static func validTurnCache(
        _ segments: [TranscriptSegment], intervals: [ProcessingInterval], duration: Double
    ) -> Bool {
        let tolerance = 1.0 / 16_000
        var intervalIndex = 0
        var previousStart = 0.0
        for segment in segments {
            guard validCached(segment, duration: duration),
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.start >= previousStart
            else { return false }
            previousStart = segment.start
            while intervalIndex < intervals.count,
                  Double(intervals[intervalIndex].endSample) / 16_000 + tolerance < segment.start {
                intervalIndex += 1
            }
            guard intervalIndex < intervals.count else { return false }
            let interval = intervals[intervalIndex]
            guard segment.start + tolerance >= Double(interval.startSample) / 16_000,
                  segment.end <= Double(interval.endSample) / 16_000 + tolerance,
                  segment.speaker == interval.speakerID
            else { return false }
        }
        return true
    }

    private static func turnFingerprint(
        source: DiarizationAudioSource.Prepared,
        intervals: [ProcessingInterval],
        engine: any TranscriptionEngine,
        asrOptionsFingerprint: String
    ) -> String {
        var hash = SHA256()
        hash.update(data: Data("turn-asr-v1|\(source.fingerprint)|\(engine.name)|\(engine.model)|\(asrOptionsFingerprint)".utf8))
        for interval in intervals {
            hash.update(data: Data("|\(interval.startSample):\(interval.endSample):\(interval.kind.rawValue):\(interval.speakerID ?? "")".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Event {
        let sample: Int64
        let speakerID: String
        let delta: Int
    }

    /// Sweep the full source, including gaps. No sample belongs to two ASR crops.
    static func partition(turns: [SpeakerTurn], sampleCount: Int64) -> [ProcessingInterval] {
        guard sampleCount > 0 else { return [] }
        let rate = 16_000.0
        var events: [Event] = []
        for turn in turns {
            guard !turn.speakerID.isEmpty, turn.start.isFinite, turn.end.isFinite,
                  turn.start >= 0, turn.start < turn.end,
                  turn.end <= Double(sampleCount) / rate + 1.0 / rate
            else { continue }
            let start = max(0, min(sampleCount, Int64((turn.start * rate).rounded())))
            let end = max(0, min(sampleCount, Int64((turn.end * rate).rounded())))
            guard start < end else { continue }
            events.append(Event(sample: start, speakerID: turn.speakerID, delta: 1))
            events.append(Event(sample: end, speakerID: turn.speakerID, delta: -1))
        }
        events.sort {
            if $0.sample != $1.sample { return $0.sample < $1.sample }
            if $0.delta != $1.delta { return $0.delta < $1.delta }
            return $0.speakerID < $1.speakerID
        }
        var boundaries = [Int64(0)]
        boundaries += events.map(\.sample)
        boundaries.append(sampleCount)
        boundaries = Array(Set(boundaries)).sorted()
        var active: [String: Int] = [:]
        var eventIndex = 0
        var out: [ProcessingInterval] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index], end = boundaries[index + 1]
            while eventIndex < events.count, events[eventIndex].sample == start {
                let event = events[eventIndex]
                let count = (active[event.speakerID] ?? 0) + event.delta
                if count <= 0 { active.removeValue(forKey: event.speakerID) }
                else { active[event.speakerID] = count }
                eventIndex += 1
            }
            let kind: IntervalKind = active.isEmpty ? .uncovered
                : active.count == 1 ? .single : .ambiguous
            let speakerID = kind == .single ? active.keys.first : nil
            if let last = out.last, last.endSample == start,
               last.kind == kind, last.speakerID == speakerID {
                out[out.count - 1] = ProcessingInterval(
                    startSample: last.startSample, endSample: end,
                    kind: kind, speakerID: speakerID)
            } else {
                out.append(ProcessingInterval(
                    startSample: start, endSample: end,
                    kind: kind, speakerID: speakerID))
            }
        }
        return out
    }

    private static func transcribe(
        interval: ProcessingInterval,
        source: DiarizationAudioSource.Prepared,
        engine: any TranscriptionEngine,
        asrPreparation: ASRPreparation
    ) async throws -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var cursor = interval.startSample
        while cursor < interval.endSample {
            try Task.checkCancellation()
            let wanted = Int(min(320_000, interval.endSample - cursor))
            let samples = try read(source.url, start: cursor, count: wanted)
            let length = interval.endSample - cursor > 320_000
                ? quietCut(samples) : samples.count
            let chunk = Array(samples.prefix(length))
            if interval.kind == .uncovered && chunk.allSatisfy({ $0 == 0 }) {
                cursor += Int64(length)
                continue
            }
            let crop = source.url.deletingLastPathComponent().appendingPathComponent(
                ".diarization-crop-\(UUID().uuidString).caf")
            let recognized = try await transcribeCrop(
                chunk, to: crop, engine: engine,
                start: cursor, speakerID: interval.speakerID,
                asrPreparation: asrPreparation)
            out += recognized
            cursor += Int64(length)
        }
        return out
    }

    static func quietCut(_ samples: [Float]) -> Int {
        let first = max(1, samples.count - 8_000)
        var best = first
        var bestEnergy = Double.infinity
        // Ten-millisecond windows; equal energy keeps the earliest cut.
        for start in stride(from: first, through: samples.count - 160, by: 160) {
            let energy = samples[start..<(start + 160)].reduce(0.0) {
                $0 + Double($1) * Double($1)
            }
            if energy < bestEnergy {
                bestEnergy = energy
                best = start
            }
        }
        return best
    }

    private static func read(_ url: URL, start: Int64, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              file.processingFormat.commonFormat == .pcmFormatFloat32,
              start >= 0, count > 0, start + Int64(count) <= file.length,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(min(4_096, count)))
        else { throw PipelineError.invalidSource }
        file.framePosition = start
        var samples: [Float] = []
        samples.reserveCapacity(count)
        while samples.count < count {
            try Task<Never, Never>.checkCancellation()
            let requested = min(Int(buffer.frameCapacity), count - samples.count)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            guard buffer.frameLength > 0, Int(buffer.frameLength) <= requested,
                  let block = buffer.floatChannelData?[0]
            else { throw PipelineError.invalidSource }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: block, count: Int(buffer.frameLength)))
        }
        return samples
    }

    private static func transcribeCrop(
        _ samples: [Float], to crop: URL, engine: any TranscriptionEngine,
        start: Int64, speakerID: String?, asrPreparation: ASRPreparation
    ) async throws -> [TranscriptSegment] {
        defer { try? FileManager.default.removeItem(at: crop) }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let padded = samples.count < minimum
            ? samples + [Float](repeating: 0, count: minimum - samples.count)
            : samples
        try writeCrop(padded, to: crop)
        try Task.checkCancellation()
        try await asrPreparation.beforeTranscribe()
        let relative = try await engine.transcribe(crop)
        try Task.checkCancellation()
        let origin = Double(start) / 16_000
        let duration = Double(samples.count) / 16_000
        let paddedDuration = Double(padded.count) / 16_000
        return try relative.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard validCached(segment, duration: paddedDuration) else { throw PipelineError.invalidASR }
            guard segment.start < duration else { return nil }
            return TranscriptSegment(
                start: origin + segment.start,
                end: origin + min(duration, segment.end),
                text: text, speaker: speakerID)
        }
    }

    private static func writeCrop(_ samples: [Float], to crop: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw PipelineError.invalidSource }
        let file = try AVAudioFile(
            forWriting: crop,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
