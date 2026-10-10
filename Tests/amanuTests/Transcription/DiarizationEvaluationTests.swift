import Darwin
import Foundation
import Testing

@testable import amanu

struct DiarizationEvaluationMetricTests {
    typealias Turn = DiarizationEvaluation.Turn
    typealias Word = DiarizationEvaluation.Word

    @Test("DER maps arbitrary hypothesis labels and penalizes missing speech")
    func derMappingAndMissingSpeech() {
        let reference = [Turn("alice", 0, 2), Turn("bob", 2, 4)]
        let swapped = [Turn("label-27", 0, 2), Turn("label-1", 2, 4)]
        let perfect = DiarizationEvaluation.der(
            reference: reference, hypothesis: swapped, collar: 0)
        #expect(perfect.der == 0)

        let missing = DiarizationEvaluation.der(
            reference: reference, hypothesis: [swapped[0]], collar: 0)
        #expect(missing.missed == 2)
        #expect(missing.der == 0.5)
    }

    @Test("Overlap can be included or excluded without hiding an unknown turn")
    func overlapAndUnknown() {
        let reference = [Turn("a", 0, 2), Turn("b", 1, 2)]
        let hypothesis = [Turn("x", 0, 2), Turn(nil, 1, 2)]
        let included = DiarizationEvaluation.der(
            reference: reference, hypothesis: hypothesis, collar: 0, includeOverlap: true)
        let excluded = DiarizationEvaluation.der(
            reference: reference, hypothesis: hypothesis, collar: 0, includeOverlap: false)
        #expect(included.missed == 1)
        #expect(included.der == 1.0 / 3.0)
        #expect(excluded.der == 0)
    }

    @Test("A fixed collar masks boundaries, and speaker mapping has no alphabetic cap")
    func collarAndManySpeakers() {
        let reference = (0..<30).map { Turn("person-\($0)", Double($0), Double($0 + 1)) }
        let hypothesis = (0..<30).map {
            Turn("cluster-\(29 - $0)", Double($0), Double($0 + 1))
        }
        #expect(DiarizationEvaluation.der(
            reference: reference, hypothesis: hypothesis, collar: 0).der == 0)
        let shifted = DiarizationEvaluation.der(
            reference: [Turn("a", 0, 2)], hypothesis: [Turn("x", 0.5, 2.5)],
            collar: 0.25)
        #expect(shifted.missed == 0.25)
        #expect(shifted.falseAlarm == 0.25)
    }

    @Test("Global assignment beats a locally greedy speaker match")
    func globallyOptimalMapping() {
        let reference = [Turn("a", 0, 9), Turn("b", 9, 17), Turn("a", 17, 25)]
        let hypothesis = [Turn("x", 0, 17), Turn("y", 17, 25)]
        let score = DiarizationEvaluation.der(
            reference: reference, hypothesis: hypothesis, collar: 0)
        #expect(score.confusion == 9)
        #expect(score.der == 9.0 / 25.0)
    }

    @Test("All unknown cannot score as perfect attribution")
    func allUnknown() {
        let reference = [Word("один", 0, 1, "a"), Word("два", 1, 2, "b")]
        let hypothesis = [Word("один", 0, 1, nil), Word("два", 1, 2, nil)]
        let result = DiarizationEvaluation.wordAttribution(
            reference: reference, hypothesis: hypothesis)
        #expect(result.unknown == 2)
        #expect(result.unknownHypothesis == result.hypothesis)
        #expect(result.wrong == 0)
        #expect(DiarizationEvaluation.der(
            reference: [Turn("a", 0, 1), Turn("b", 1, 2)],
            hypothesis: [Turn(nil, 0, 2)], collar: 0).der == 1)
    }

    @Test("Word attribution reports unknown separately from wrong speakers and ASR errors")
    func wordErrors() {
        let reference = [
            Word("Привет", 0, 1, "a"),
            Word("Swift", 1, 2, "b"),
            Word("да", 2, 3, "a"),
        ]
        let hypothesis = [
            Word("привет", 0, 1, "x"),
            Word("swift", 1, 2, "x"),
            Word("да", 2, 3, nil),
        ]
        let result = DiarizationEvaluation.wordAttribution(
            reference: reference, hypothesis: hypothesis)
        #expect(result.matched == 3)
        #expect(result.wrong == 1)
        #expect(result.unknown == 1)
        #expect(result.unknownHypothesis == 1)
        #expect(DiarizationEvaluation.wer(reference: reference, hypothesis: hypothesis) == 0)
        #expect(DiarizationEvaluation.wer(
            reference: reference,
            hypothesis: [Word("привет", 0, 1, nil), Word("нет", 2, 3, nil)]) == 2.0 / 3.0)
    }
}

/// Explicitly opt in with a permitted, annotated corpus and already verified
/// model assets. No ordinary test run prepares a model or reads private audio.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["AMANU_DIAR_EVAL_RUN"] == "1"
        && ProcessInfo.processInfo.environment["AMANU_DIAR_EVAL_CORPUS"] != nil
        && ProcessInfo.processInfo.environment["AMANU_DIAR_EVAL_MODELS"] != nil
        && ProcessInfo.processInfo.environment["AMANU_DIAR_EVAL_REPORT"] != nil)
)
struct DiarizationEvaluationTests {
    private struct Corpus: Decodable {
        let version: Int
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let variants: [Variant]
        let referenceTurns: [DiarizationEvaluation.Turn]
        let referenceWords: [DiarizationEvaluation.Word]
        let asrWords: [DiarizationEvaluation.Word]?
        let pr37Turns: [String: [DiarizationEvaluation.Turn]]?
        let gigaAMOldWords: [DiarizationEvaluation.Word]?
        let gigaAMNewWords: [DiarizationEvaluation.Word]?
    }

    private struct Variant: Decodable {
        let format: String
        let audio: String
    }

    private struct Score: Encodable {
        let derOverlapIncluded: Double?
        let derOverlapExcluded: Double?
        let missSeconds: Double
        let falseAlarmSeconds: Double
        let confusionSeconds: Double
        let referenceSpeakerSeconds: Double
        let pr37DER: Double?
        let attributedMatchedWords: Int?
        let attributedWrongWords: Int?
        let attributedUnknownWords: Int?
        let hypothesisWords: Int?
        let unknownHypothesisWords: Int?
        let attributedUnmatchedReferenceWords: Int?
        let asrWER: Double?
        let gigaAMOldWER: Double?
        let gigaAMNewWER: Double?
    }

    private struct Observation: Encodable {
        let sampleNumber: Int
        let variant: String
        let sourceFingerprint: String
        let threshold: Double
        let run: Int
        let audioSeconds: Double
        let prepareSeconds: Double
        let diarizationSeconds: Double
        let wallTimePerAudio: Double
        let peakProcessRSSBytes: Int64
        let detectedSpeakerCount: Int
        let score: Score
    }

    private struct Report: Encodable {
        let schemaVersion: Int
        let collarSeconds: Double
        let mapping: String
        let overlapPolicy: String
        let hardwareModel: String
        let osVersion: String
        let cpuCount: Int
        let modelRevision: String
        let modelFingerprint: String
        let runtime: String
        let sampleCount: Int
        let variantsSameDecodedPCM: [Bool?]
        let observations: [Observation]
    }

    @Test("Annotated corpus: thresholds, repeats, alignment and private numeric report")
    func evaluatePreparedLocalModel() async {
        do {
            try await run()
        } catch {
            Issue.record("Local diarization evaluation failed; inspect the private fixture and model assets locally")
        }
    }

    private func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let corpusURL = URL(fileURLWithPath: environment["AMANU_DIAR_EVAL_CORPUS"]!)
            .resolvingSymlinksInPath()
        let modelURL = URL(fileURLWithPath: environment["AMANU_DIAR_EVAL_MODELS"]!,
                           isDirectory: true).resolvingSymlinksInPath()
        let reportURL = URL(fileURLWithPath: environment["AMANU_DIAR_EVAL_REPORT"]!)
            .resolvingSymlinksInPath()
        guard corpusURL.path.hasPrefix("/"), modelURL.path.hasPrefix("/"),
              corpusURL.path != repository.path,
              !corpusURL.path.hasPrefix(repository.path + "/"),
              !modelURL.path.hasPrefix(repository.path + "/"),
              reportURL.path.hasPrefix(repository.appendingPathComponent(".build").path + "/"),
              corpusURL.path != reportURL.path
        else { throw EvaluationError.invalidInput }

        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        guard corpus.version == 1, !corpus.samples.isEmpty else {
            throw EvaluationError.invalidInput
        }
        let store = DiarizationModelStore(directory: modelURL)
        guard await store.isReady() else { throw EvaluationError.modelNotReady }
        let modelFingerprint = try await store.fingerprint()
        let home = Home.sandbox()
        defer { try? FileManager.default.removeItem(at: home.url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: home.url.path)
        let output = try await Home.$scoped.withValue(home) {
            try await evaluate(corpus, in: corpusURL.deletingLastPathComponent(),
                               scratch: home.url, store: store,
                               modelFingerprint: modelFingerprint)
        }
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
            ofItemAtPath: reportURL.deletingLastPathComponent().path)
        let encoded = JSONEncoder()
        encoded.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoded.encode(output).write(to: reportURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: reportURL.path)
        print("Local diarization evaluation: numeric report written inside .build")
    }

    private func evaluate(
        _ corpus: Corpus, in corpusDirectory: URL, scratch: URL,
        store: DiarizationModelStore, modelFingerprint: String
    ) async throws -> Report {
        var observations: [Observation] = []
        var pcmComparisons: [Bool?] = []
        for (sampleIndex, sample) in corpus.samples.enumerated() {
            guard !sample.variants.isEmpty else { throw EvaluationError.invalidInput }
            var prepared: [(String, DiarizationAudioSource.Prepared)] = []
            for (variantIndex, variant) in sample.variants.enumerated() {
                guard ["caf", "aac", "pcm"].contains(variant.format) else {
                    throw EvaluationError.invalidInput
                }
                let input = corpusDirectory.appendingPathComponent(variant.audio)
                    .resolvingSymlinksInPath()
                guard input.path.hasPrefix(corpusDirectory.path + "/"),
                      FileManager.default.fileExists(atPath: input.path)
                else { throw EvaluationError.invalidInput }
                let source = try DiarizationAudioSource.prepare(
                    input: input, channel: nil, trackID: "source", clock: .sessionAligned,
                    destination: scratch.appendingPathComponent(
                        "sample-\(sampleIndex)-variant-\(variantIndex).caf"))
                try validate(sample, duration: source.duration)
                prepared.append((variant.format, source))
            }
            pcmComparisons.append(prepared.count < 2 ? nil
                                  : Set(prepared.map { $0.1.fingerprint }).count == 1)

            for threshold in [0.6, 0.7, 0.8] {
                let settings = DiarizationSettings(enabled: true, threshold: threshold,
                                                   model: .community1)
                let runtime = DiarizationEngine(settings: settings, store: store)
                let prepStart = ProcessInfo.processInfo.systemUptime
                try await runtime.prepare()
                let prepareSeconds = ProcessInfo.processInfo.systemUptime - prepStart
                do {
                    for (format, source) in prepared {
                        for run in 1...2 {
                            let started = ProcessInfo.processInfo.systemUptime
                            let turns = try await runtime.diarize(source.url)
                            let elapsed = ProcessInfo.processInfo.systemUptime - started
                            let hypothesis = turns.map {
                                DiarizationEvaluation.Turn($0.speakerID, $0.start, $0.end)
                            }
                            let included = DiarizationEvaluation.der(
                                reference: sample.referenceTurns, hypothesis: hypothesis)
                            let excluded = DiarizationEvaluation.der(
                                reference: sample.referenceTurns, hypothesis: hypothesis,
                                includeOverlap: false)
                            let wordScore = try sample.asrWords.map { words in
                                try scoreWords(words, turns: turns, duration: source.duration,
                                               reference: sample.referenceWords)
                            }
                            let control = sample.pr37Turns?[String(format: "%.1f", threshold)]
                                .map { DiarizationEvaluation.der(
                                    reference: sample.referenceTurns, hypothesis: $0).der }
                            let score = Score(
                                derOverlapIncluded: included.der,
                                derOverlapExcluded: excluded.der,
                                missSeconds: included.missed,
                                falseAlarmSeconds: included.falseAlarm,
                                confusionSeconds: included.confusion,
                                referenceSpeakerSeconds: included.reference,
                                pr37DER: control ?? nil,
                                attributedMatchedWords: wordScore?.matched,
                                attributedWrongWords: wordScore?.wrong,
                                attributedUnknownWords: wordScore?.unknown,
                                hypothesisWords: wordScore?.hypothesis,
                                unknownHypothesisWords: wordScore?.unknownHypothesis,
                                attributedUnmatchedReferenceWords: wordScore?.unmatched,
                                asrWER: sample.asrWords.flatMap {
                                    DiarizationEvaluation.wer(
                                        reference: sample.referenceWords, hypothesis: $0)
                                },
                                gigaAMOldWER: sample.gigaAMOldWords.flatMap {
                                    DiarizationEvaluation.wer(
                                        reference: sample.referenceWords, hypothesis: $0)
                                },
                                gigaAMNewWER: sample.gigaAMNewWords.flatMap {
                                    DiarizationEvaluation.wer(
                                        reference: sample.referenceWords, hypothesis: $0)
                                })
                            observations.append(Observation(
                                sampleNumber: sampleIndex + 1, variant: format,
                                sourceFingerprint: source.fingerprint,
                                threshold: threshold, run: run,
                                audioSeconds: source.duration,
                                prepareSeconds: prepareSeconds,
                                diarizationSeconds: elapsed,
                                wallTimePerAudio: elapsed / source.duration,
                                peakProcessRSSBytes: peakRSS(),
                                detectedSpeakerCount: Set(turns.map(\.speakerID)).count,
                                score: score))
                        }
                    }
                } catch {
                    await runtime.release()
                    throw error
                }
                await runtime.release()
            }
        }
        return Report(
            schemaVersion: 1, collarSeconds: 0.25,
            mapping: "global maximum coactive time, one-to-one Hungarian assignment",
            overlapPolicy: "both included and excluded reported; excluded removes reference overlap",
            hardwareModel: hardwareModel(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            cpuCount: ProcessInfo.processInfo.processorCount,
            modelRevision: DiarizationModelStore.revision,
            modelFingerprint: modelFingerprint,
            runtime: "FluidAudio OfflineDiarizerManager 0.15.5 (Package.resolved)",
            sampleCount: corpus.samples.count,
            variantsSameDecodedPCM: pcmComparisons,
            observations: observations)
    }

    private func scoreWords(
        _ hypothesis: [DiarizationEvaluation.Word], turns: [SpeakerTurn],
        duration: Double, reference: [DiarizationEvaluation.Word]
    ) throws -> DiarizationEvaluation.Attribution {
        guard !hypothesis.isEmpty else {
            return DiarizationEvaluation.wordAttribution(reference: reference, hypothesis: [])
        }
        let words = hypothesis.map {
            TranscriptWord(start: $0.start, end: $0.end, text: $0.text)
        }
        let segment = TranscriptSegment(
            start: words.first!.start, end: words.last!.end,
            text: words.map(\.text).joined(separator: " "), words: words)
        let aligned = try DiarizationAlignment.align(
            segments: [segment], turns: turns, duration: duration, labelPrefix: "speaker")
        let assigned = aligned.assignments.map {
            DiarizationEvaluation.Word($0.word.text, $0.word.start,
                                       $0.word.end, $0.speakerID)
        }
        return DiarizationEvaluation.wordAttribution(
            reference: reference, hypothesis: assigned)
    }

    private func validate(_ sample: Sample, duration: Double) throws {
        guard !sample.referenceTurns.isEmpty else { throw EvaluationError.invalidInput }
        if sample.asrWords != nil && (sample.referenceWords.isEmpty
            || sample.referenceWords.contains(where: { $0.speaker == nil })) {
            throw EvaluationError.invalidInput
        }
        if let keys = sample.pr37Turns?.keys,
           !Set(keys).isSubset(of: ["0.6", "0.7", "0.8"]) {
            throw EvaluationError.invalidInput
        }
        let turns = sample.referenceTurns + (sample.pr37Turns?.values.flatMap { $0 } ?? [])
        guard turns.allSatisfy({ valid($0.start, $0.end, duration: duration)
            && $0.speaker.map({ !$0.isEmpty }) == true }),
            (sample.referenceWords + (sample.asrWords ?? [])
                + (sample.gigaAMOldWords ?? []) + (sample.gigaAMNewWords ?? []))
                .allSatisfy({ valid($0.start, $0.end, duration: duration)
                    && !$0.text.isEmpty })
        else { throw EvaluationError.invalidInput }
    }

    private func valid(_ start: Double, _ end: Double, duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && start < end
            && end <= duration + 0.001
    }

    private func peakRSS() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }

    private func hardwareModel() -> String {
        var count = 0
        guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 1 else {
            return "unavailable"
        }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else {
            return "unavailable"
        }
        return String(cString: bytes)
    }

    private enum EvaluationError: Error { case invalidInput, modelNotReady }
}
