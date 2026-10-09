import AVFoundation
import Foundation
import Testing
@testable import amanu

struct LocalDiarizationPipelineTests {
    @Test("Only exact zero remote PCM with no contrary ASR text accepts noSpeechDetected")
    func knownDigitalSilence() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input.caf")
        let destination = directory.appendingPathComponent("diarization-source-them.caf")
        try TestAudio.write(to: input, seconds: 1, sampleRate: 16_000) { _, _ in 0 }
        let zero = try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: "them", clock: .sessionAligned,
            destination: destination)
        let engine = CachedWordEngine()
        let runtime = NoSpeechRuntime()
        let settings = DiarizationSettings(enabled: true)
        let preparations = PreparationCounter()

        let empty = try await LocalDiarizationPipeline.run(
            source: zero, engine: engine, runtime: runtime, settings: settings,
            prepareASR: { await preparations.record() },
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "fixture-asr")
        #expect(empty.segments.isEmpty)
        #expect(empty.rawTurns.isEmpty)
        #expect(empty.asr.isEmpty)
        #expect(await engine.calls == 0)
        #expect(await preparations.count == 0)

        let contrary = [TranscriptSegment(start: 0, end: 0.5, text: "heard words")]
        do {
            _ = try await LocalDiarizationPipeline.run(
                source: zero, engine: engine, runtime: runtime, settings: settings,
                cachedASR: contrary,
                modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
                asrOptionsFingerprint: "fixture-asr")
            Issue.record("recognized words must prevent a silent-side completion")
        } catch LocalDiarizationRuntimeError.noSpeechDetected {}

        do {
            _ = try await LocalDiarizationPipeline.run(
                source: zero, engine: engine, runtime: runtime, settings: settings,
                cachedASR: [TranscriptSegment(
                    start: 0, end: 0.5, text: "",
                    words: [TranscriptWord(start: 0, end: 0.5, text: "heard")])],
                modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
                asrOptionsFingerprint: "fixture-asr")
            Issue.record("cached word text must prevent a silent-side completion")
        } catch LocalDiarizationRuntimeError.noSpeechDetected {}

        do {
            _ = try await LocalDiarizationPipeline.run(
                source: zero, engine: engine, runtime: runtime, settings: settings,
                cachedTurnASR: .init(turnFingerprint: "prior", segments: contrary),
                modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
                asrOptionsFingerprint: "fixture-asr")
            Issue.record("cached turn words must prevent a silent-side completion")
        } catch LocalDiarizationRuntimeError.noSpeechDetected {}

        try TestAudio.write(to: input, seconds: 1, sampleRate: 16_000) { _, frame in
            frame == 8_000 ? 0.001 : 0
        }
        let quiet = try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: "them", clock: .sessionAligned,
            destination: destination)
        do {
            _ = try await LocalDiarizationPipeline.run(
                source: quiet, engine: engine, runtime: runtime, settings: settings,
                modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
                asrOptionsFingerprint: "fixture-asr")
            Issue.record("nonzero quiet audio must stay retryable")
        } catch LocalDiarizationRuntimeError.noSpeechDetected {}
        try DiarizationAudioSource.verify(quiet)
        #expect(await engine.calls == 0)
    }

    @Test("A long crop cuts at the first minimum-energy 10 ms window in its last half-second")
    func quietCutUsesLocalMinimum() {
        var samples = [Float](repeating: 0.2, count: 320_000)
        samples.replaceSubrange(316_800..<316_960, with: [Float](repeating: 0, count: 160))
        #expect(LocalDiarizationPipeline.quietCut(samples) == 316_800)
    }

    @Test("Short replies and uncovered gaps partition the whole sample timeline")
    func shortRepliesAndGaps() {
        let intervals = LocalDiarizationPipeline.partition(turns: [
            SpeakerTurn(speakerID: "A", start: 0.1, end: 0.25),
            SpeakerTurn(speakerID: "B", start: 0.3, end: 0.45),
        ], sampleCount: 16_000)
        #expect(intervals.map(\.kind) == [
            .uncovered, .single, .uncovered, .single, .uncovered,
        ])
        #expect(intervals.map(\.endSample).last == 16_000)
        for index in 1..<intervals.count {
            #expect(intervals[index].startSample == intervals[index - 1].endSample)
        }
        #expect(intervals.reduce(Int64(0)) { $0 + $1.endSample - $1.startSample } == 16_000)
    }

    @Test("Cached word ASR splits one long phrase among three imported speakers without another ASR call")
    func cachedWordsAcrossSpeakers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(in: directory, seconds: 6, trackID: "speaker")
        let runtime = FixedTurns(turns: [
            SpeakerTurn(speakerID: "A", start: 0, end: 2),
            SpeakerTurn(speakerID: "B", start: 2, end: 4),
            SpeakerTurn(speakerID: "C", start: 4, end: 6),
        ])
        let engine = CachedWordEngine()
        let preparations = PreparationCounter()
        let cached = [TranscriptSegment(
            start: 0, end: 6, text: "первый второй третий",
            words: [
                TranscriptWord(start: 0.5, end: 1.5, text: "первый "),
                TranscriptWord(start: 2.5, end: 3.5, text: "второй "),
                TranscriptWord(start: 4.5, end: 5.5, text: "третий"),
            ])]

        let result = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime,
            settings: DiarizationSettings(enabled: true), cachedASR: cached,
            prepareASR: { await preparations.record() },
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "fixture-asr")

        #expect(result.resolution == .word)
        #expect(result.segments.map(\.speaker) == ["speaker A", "speaker B", "speaker C"])
        #expect(result.assignments.count == 3)
        #expect(result.segments.map(\.text).joined(separator: " ").split(separator: " ")
                == ["первый", "второй", "третий"])
        #expect(await engine.calls == 0)
        #expect(await preparations.count == 0)
    }

    @Test("Missing word times replace the coarse transcript with separate turn ASR")
    func missingWordsFallBackWithoutDuplicateText() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(in: directory, seconds: 6)
        let runtime = FixedTurns(turns: [
            SpeakerTurn(speakerID: "A", start: 0, end: 2),
            SpeakerTurn(speakerID: "B", start: 2, end: 4),
            SpeakerTurn(speakerID: "C", start: 4, end: 6),
        ])
        let engine = MissingWordEngine()
        let preparations = PreparationCounter()

        let result = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime,
            settings: DiarizationSettings(enabled: true),
            prepareASR: { await preparations.record() },
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "fixture-asr")

        #expect(result.resolution == .turn)
        #expect(result.asr.map(\.text) == ["long phrase"])
        #expect(result.segments.map(\.speaker) == ["them A", "them B", "them C"])
        #expect(result.segments.allSatisfy { !$0.text.contains("long phrase") })
        #expect(await engine.calls == 4)
        #expect(await preparations.count == 1)
    }

    @Test("A failed later crop keeps durable audio and removes temporary crops")
    func failedCropKeepsSource() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(in: directory, seconds: 6)
        let runtime = FixedTurns(turns: [
            SpeakerTurn(speakerID: "A", start: 0, end: 3),
            SpeakerTurn(speakerID: "B", start: 3, end: 6),
        ])
        let engine = FailingCropEngine()
        do {
            _ = try await LocalDiarizationPipeline.run(
                source: source, engine: engine, runtime: runtime,
                settings: DiarizationSettings(enabled: true),
                modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
                asrOptionsFingerprint: "fixture-asr")
            Issue.record("the second crop must fail")
        } catch is CropFailure {}

        #expect(FileManager.default.fileExists(atPath: source.url.path))
        try DiarizationAudioSource.verify(source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".diarization-crop-") })
    }

    @Test("GigaAM recognizes each diarized voice in a separate, disjoint crop")
    func threeVoicesAndUnknownRegions() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(in: directory, seconds: 6)
        let runtime = FixedTurns(turns: [
            SpeakerTurn(speakerID: "A", start: 0, end: 3),
            SpeakerTurn(speakerID: "B", start: 2, end: 5),
            SpeakerTurn(speakerID: "bad", start: .nan, end: 6),
        ])
        let engine = CropRecordingEngine()

        let result = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime,
            settings: DiarizationSettings(enabled: true, threshold: 0.6),
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "fixture-asr")

        #expect(result.resolution == .turn)
        #expect(result.segments.map(\.speaker) == ["them A", "them ?", "them B", "them ?"])
        #expect(result.segments.map(\.start_ms) == [0, 2_000, 3_000, 5_000])
        #expect(result.segments.map(\.end_ms) == [2_000, 3_000, 5_000, 6_000])
        #expect(await engine.sampleCounts == [32_000, 16_000, 32_000, 16_000])
        #expect(result.asr.count == 4)
        #expect(result.rawTurns.count == 2)
        #expect(result.rejectedTurnCount == 1)
        #expect(result.turnFingerprint != nil)
    }

    @Test("Long turns are cropped at no more than 20 seconds and a matching turn cache skips ASR")
    func longTurnAndCache() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(in: directory, seconds: 42)
        let runtime = FixedTurns(turns: [SpeakerTurn(speakerID: "A", start: 0, end: 42)])
        let engine = CropRecordingEngine()
        let settings = DiarizationSettings(enabled: true, threshold: 0.6)

        let first = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime, settings: settings,
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "fixture-asr")
        let counts = await engine.sampleCounts
        #expect(counts.count == 3)
        #expect(counts.allSatisfy { $0 <= 320_000 })
        #expect(counts.reduce(0, +) == 42 * 16_000)
        #expect(first.segments.map(\.speaker) == ["them", "them", "them"])

        let repeated = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime, settings: settings,
            cachedTurnASR: .init(turnFingerprint: try #require(first.turnFingerprint),
                                 segments: first.asr),
            modelFingerprint: "fixture-model", optionsFingerprint: "changed-threshold-options",
            asrOptionsFingerprint: "fixture-asr")
        #expect(await engine.sampleCounts == counts)
        #expect(repeated.segments.map(\.text) == first.segments.map(\.text))

        let newASROptions = try await LocalDiarizationPipeline.run(
            source: source, engine: engine, runtime: runtime, settings: settings,
            cachedTurnASR: .init(turnFingerprint: try #require(first.turnFingerprint),
                                 segments: first.asr),
            modelFingerprint: "fixture-model", optionsFingerprint: "fixture-options",
            asrOptionsFingerprint: "changed-asr-language")
        #expect(await engine.sampleCounts.count == counts.count * 2)
        #expect(newASROptions.turnFingerprint != first.turnFingerprint)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-diarization-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSource(
        in directory: URL, seconds: Int, trackID: String = "them"
    ) throws -> DiarizationAudioSource.Prepared {
        let input = directory.appendingPathComponent("input.caf")
        try TestAudio.write(to: input, seconds: Double(seconds), sampleRate: 16_000) { _, _ in 0.2 }
        return try DiarizationAudioSource.prepare(
            input: input, channel: nil, trackID: trackID, clock: .sessionAligned,
            destination: directory.appendingPathComponent("diarization-source-\(trackID).caf"))
    }
}

private actor CachedWordEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model = "fixture"
    nonisolated let input: TranscriptionInput = .perTrack
    private(set) var calls = 0
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls += 1
        return []
    }
    func release() async {}
}

private actor MissingWordEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model = "fixture"
    nonisolated let input: TranscriptionInput = .perTrack
    private(set) var calls = 0
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls += 1
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return [TranscriptSegment(
            start: 0, end: duration,
            text: calls == 1 ? "long phrase" : "turn \(calls - 1)")]
    }
    func release() async {}
}

private struct CropFailure: Error {}

private actor FailingCropEngine: TranscriptionEngine {
    nonisolated let name = "gigaam"
    nonisolated let model = "fixture"
    nonisolated let input: TranscriptionInput = .perTrack
    private var calls = 0
    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls += 1
        if calls == 2 { throw CropFailure() }
        let file = try AVAudioFile(forReading: audio)
        return [TranscriptSegment(start: 0, end: Double(file.length) / 16_000, text: "first")]
    }
    func release() async {}
}

private actor FixedTurns: LocalDiarizationRuntime {
    let turns: [SpeakerTurn]
    init(turns: [SpeakerTurn]) { self.turns = turns }
    func prepare() async throws {}
    func diarize(_ audio: URL) async throws -> [SpeakerTurn] { turns }
    func release() async {}
}

private actor NoSpeechRuntime: LocalDiarizationRuntime {
    func prepare() async throws {}
    func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
        throw LocalDiarizationRuntimeError.noSpeechDetected
    }
    func release() async {}
}

private actor PreparationCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor CropRecordingEngine: TranscriptionEngine {
    nonisolated let name = "gigaam"
    nonisolated let model = "fixture"
    nonisolated let input: TranscriptionInput = .perTrack
    private(set) var sampleCounts: [Int] = []

    func prepare() async throws {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let file = try AVAudioFile(forReading: audio)
        let count = Int(file.length)
        sampleCounts.append(count)
        return [TranscriptSegment(start: 0, end: Double(count) / 16_000,
                                  text: "фрагмент \(sampleCounts.count)")]
    }
    func release() async {}
}
