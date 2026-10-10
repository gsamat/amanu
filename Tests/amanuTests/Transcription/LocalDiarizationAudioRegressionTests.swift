import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import amanu

struct LocalDiarizationAudioRegressionTests {
    @Test("Opt-in private audio reproduces the local ASR and diarization path")
    func stagedAudio() async {
        guard let path = ProcessInfo.processInfo.environment["AMANU_DIAR_AUDIO_REPRO_ROOT"] else {
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        guard (root.path.hasPrefix("/tmp/amanu-diarization-audio-")
                || root.path.hasPrefix("/private/tmp/amanu-diarization-audio-")),
              root.lastPathComponent == "private" else {
            Issue.record("private audio fixture must be in its disposable temporary directory")
            return
        }
        let modelDirectory = root.appendingPathComponent("models", isDirectory: true)
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3),
              DiarizationModelStore.isReady(at: modelDirectory, model: .lsEendAMI) else {
            Issue.record("offline model cache is incomplete")
            return
        }

        do {
            let source = try JSONDecoder().decode(
                DiarizationAudioSource.Prepared.self,
                from: Data(contentsOf: root.appendingPathComponent("prepared-source.json")))
            guard source.url.resolvingSymlinksInPath()
                    == root.appendingPathComponent("source.caf").resolvingSymlinksInPath(),
                  source.sampleRate == 16_000, source.sampleCount > 0 else {
                Issue.record("private prepared source does not match staged PCM")
                return
            }
            try DiarizationAudioSource.verify(source)
            let scratch = root.appendingPathComponent(".source-check-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let recreated = try DiarizationAudioSource.prepare(
                input: root.appendingPathComponent("input.m4a"), channel: nil,
                trackID: source.trackID, clock: source.clock, destination: scratch)
            let sourceMatchesInput = recreated.sampleCount == source.sampleCount
                && recreated.fingerprint == source.fingerprint
            #expect(sourceMatchesInput)
            let cached = try JSONDecoder().decode(
                [TranscriptSegment].self,
                from: Data(contentsOf: root.appendingPathComponent("cached-asr.json")))
            let store = DiarizationModelStore(model: .lsEendAMI, directory: modelDirectory)
            let fingerprint = try await store.fingerprint()
            await Home.$scoped.withValue(Home.sandbox(at: root.appendingPathComponent("profile"))) {
                let settings = DiarizationSettings(enabled: true, threshold: 0.6, model: .lsEendAMI)
                let runtime = DiarizationEngine(settings: settings, store: store)
                let engine = RecordingParakeetEngine()
                do {
                    try await runtime.prepare()
                    try await engine.prepare()
                    let full = try await engine.transcribeFullSource(source.url)
                    let fullHasText = full.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    let fullHasWords = full.contains { $0.words?.isEmpty == false }
                    let fullTimingValid = full.allSatisfy {
                        $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                            && $0.start < $0.end && $0.end <= source.duration + 1.0 / 16_000
                    }
                    #expect(fullHasText)
                    #expect(fullHasWords)
                    #expect(fullTimingValid)

                    let result = try await LocalDiarizationPipeline.run(
                        source: source, engine: engine, runtime: runtime, settings: settings,
                        cachedASR: cached, modelFingerprint: fingerprint,
                        optionsFingerprint: "ls-eend-ami|threshold=0.6",
                        asrOptionsFingerprint: engine.optionsFingerprint)
                    let counts = await engine.cropSampleCounts
                    let resultHasText = result.segments.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    let resultHasAssignedSpeaker = result.segments.contains {
                        !$0.speaker.hasSuffix(" ?")
                    }
                    let resultTimingValid = result.segments.allSatisfy {
                        $0.start_ms >= 0 && $0.start_ms < $0.end_ms
                            && $0.end_ms <= Int((source.duration * 1_000).rounded())
                    }
                    #expect(!counts.isEmpty)
                    #expect(counts.allSatisfy { $0 >= 4_800 && $0 <= 320_000 })
                    #expect(result.resolution == .turn)
                    #expect(resultHasText)
                    #expect(resultHasAssignedSpeaker)
                    #expect(resultTimingValid)
                    let aligned = try DiarizationAlignment.align(
                        segments: full, turns: result.rawTurns, duration: source.duration,
                        labelPrefix: "speaker")
                    let freshHasText = aligned.segments.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    let freshHasAssignedSpeaker = aligned.segments.contains {
                        !$0.speaker.hasSuffix(" ?")
                    }
                    let freshTimingValid = aligned.segments.allSatisfy {
                        $0.start_ms >= 0 && $0.start_ms < $0.end_ms
                            && $0.end_ms <= Int((source.duration * 1_000).rounded())
                    }
                    #expect(freshHasText)
                    #expect(freshHasAssignedSpeaker)
                    #expect(freshTimingValid)
                    print("Private diarization: seconds=\(Int(source.duration)), crops=\(counts.count), minimumSamples=\(counts.min() ?? 0), segments=\(result.segments.count), wordAlignedSegments=\(aligned.segments.count), resolution=\(result.resolution.rawValue)")
                } catch {
                    let counts = await engine.cropSampleCounts
                    let isMinimumError: Bool
                    if let asrError = error as? ASRError, case .invalidAudioData = asrError {
                        isMinimumError = true
                    } else {
                        isMinimumError = false
                    }
                    print("Private diarization failure: type=\(type(of: error)), minimumError=\(isMinimumError), crops=\(counts.count), minimumSamples=\(counts.min() ?? 0)")
                    Issue.record("private audio pipeline failed; see aggregate status only")
                }
                await engine.release()
                await runtime.release()
            }
        } catch {
            Issue.record("private audio fixture could not be read or verified")
        }
    }
}

private actor RecordingParakeetEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model: String
    nonisolated let optionsFingerprint: String
    nonisolated let input: TranscriptionInput = .perTrack
    private let wrapped: ParakeetEngine
    private(set) var cropSampleCounts: [Int] = []

    init() {
        let wrapped = ParakeetEngine(version: .v3)
        self.wrapped = wrapped
        model = wrapped.model
        optionsFingerprint = wrapped.optionsFingerprint
    }

    func prepare() async throws { try await wrapped.prepare() }
    func transcribeFullSource(_ audio: URL) async throws -> [TranscriptSegment] {
        try await wrapped.transcribe(audio)
    }
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        cropSampleCounts.append(Int(try AVAudioFile(forReading: audio).length))
        if cropSampleCounts.count.isMultiple(of: 100) {
            print("Private diarization progress: crops=\(cropSampleCounts.count), minimumSamples=\(cropSampleCounts.min() ?? 0)")
        }
        return try await wrapped.transcribe(audio)
    }
    func release() async { await wrapped.release() }
}
