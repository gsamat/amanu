import AVFoundation
import Foundation
import os
import Testing
@testable import amanu

struct WhisperEngineTests {
    @Test("Audio is decoded to bounded 16 kHz mono chunks")
    func pcmReaderResamplesInBoundedChunks() throws {
        let audio = try makeAudio(seconds: 1, sampleRate: 48_000, channels: 2)
        let reader = try WhisperPCMReader(audio: audio, maximumSamples: 4_000)
        var chunks: [[Float]] = []
        while let chunk = try reader.nextChunk() { chunks.append(chunk) }

        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 4_000 })
        #expect(chunks.reduce(0) { $0 + $1.count } == 16_000)
        let settled = chunks[0].suffix(2_000)
        #expect(abs(settled.reduce(0, +) / Float(settled.count) - 0.25) < 0.02)
    }

    @Test("Tiny output chunks do not mistake converter input starvation for EOF")
    func pcmReaderKeepsReadingAcrossDryConversions() throws {
        let audio = try makeAudio(seconds: 0.01, sampleRate: 48_000, channels: 1)
        let reader = try WhisperPCMReader(audio: audio, maximumSamples: 1)
        var samples: [Float] = []
        while let chunk = try reader.nextChunk() { samples += chunk }
        #expect(samples.count == 160)
    }

    @Test("Chunk timestamps are relative to the original audio and a lone language reaches whisper.cpp")
    func engineOffsetsSegmentsAndPassesLanguage() async throws {
        let audio = try makeAudio(seconds: 1.25, sampleRate: 16_000, channels: 1)
        let store = try fixtureStore()
        let runtime = RecordingWhisperRuntime()
        let engine = WhisperEngine(
            modelStore: store,
            runtime: runtime,
            expectedLanguages: ["en"],
            chunkDuration: 0.5)

        try await engine.prepare()
        let segments = try await engine.transcribe(audio)

        #expect(engine.name == "whisper")
        #expect(engine.model == "fixture")
        #expect(engine.input.metadataName == "per-track")
        #expect(await runtime.languages == ["en", "en", "en"])
        #expect(await runtime.sampleCounts == [8_000, 8_000, 4_000])
        #expect(segments.map(\.start) == [0, 0.5, 1.0])
        #expect(segments.map(\.end) == [0.5, 1.0, 1.25])
        #expect(segments.allSatisfy { $0.speaker == nil })
    }

    @Test("Word mode passes through native words with each chunk offset exactly once")
    func wordModeUsesAbsoluteChunkClock() async throws {
        let audio = try makeAudio(seconds: 1.25, sampleRate: 16_000, channels: 1)
        let runtime = TimedWhisperRuntime()
        let engine = WhisperEngine(
            modelStore: try fixtureStore(), runtime: runtime,
            expectedLanguages: ["en"], chunkDuration: 0.5, wordTimings: true)

        try await engine.prepare()
        let segments = try await engine.transcribe(audio)

        #expect(await runtime.modes == [true, true, true])
        #expect(segments.flatMap { $0.words ?? [] }.map(\.start) == [0, 0.5, 1.0])
        #expect(segments.flatMap { $0.words ?? [] }.map(\.end) == [0.5, 1.0, 1.25])
    }

    @Test("Whisper immutable ASR options distinguish language and timing mode")
    func optionsSnapshot() {
        let english = WhisperEngine(expectedLanguages: ["en"], wordTimings: true)
        let russian = WhisperEngine(expectedLanguages: ["ru"], wordTimings: true)
        let plain = WhisperEngine(expectedLanguages: ["en"], wordTimings: false)
        #expect(english.optionsFingerprint != russian.optionsFingerprint)
        #expect(english.optionsFingerprint != plain.optionsFingerprint)
    }

    /// "Mostly Russian" is Russian and English, and a pin on Russian is how
    /// the English half of a meeting comes back as Cyrillic nonsense. The
    /// cloud engines already left the language to detection here; Whisper
    /// was handed the configured language as a hard pin.
    @Test(
        "A configured language with English beside it is not pinned",
        .freshHome(config: #"{"transcription": {"language": "ru"}}"#))
    func mostlyRussianIsDetectedNotPinned() async throws {
        let audio = try makeAudio(seconds: 0.25, sampleRate: 16_000, channels: 1)
        let runtime = RecordingWhisperRuntime()
        let engine = WhisperEngine(modelStore: try fixtureStore(), runtime: runtime)

        try await engine.prepare()
        _ = try await engine.transcribe(audio)

        #expect(await runtime.languages == [nil])
        let queued = try #require(
            EngineResolver.localEngine(named: "whisper") as? WhisperEngine)
        #expect(queued.language == nil)
    }

    @Test("A runtime failure stays retryable instead of being mislabeled as bad audio")
    func runtimeFailureIsNotPermanent() async throws {
        let engine = WhisperEngine(modelStore: try fixtureStore(), runtime: FailingWhisperRuntime())
        try await engine.prepare()
        let audio = try makeAudio(seconds: 0.1, sampleRate: 16_000, channels: 1)

        await #expect(throws: RuntimeFixtureError.self) {
            try await engine.transcribe(audio)
        }
    }

    private func fixtureStore() throws -> WhisperModelStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-whisper-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = WhisperModelStore.Manifest(
            id: "fixture", fileName: "model.bin", revision: "fixture",
            downloadURL: URL(string: "https://example.test/model.bin")!,
            expectedBytes: 5,
            sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4")
        try Data("model".utf8).write(to: directory.appendingPathComponent(manifest.fileName))
        return WhisperModelStore(directory: directory, manifest: manifest) { _, _, _ in
            Issue.record("a verified local model must not download")
        }
    }

    private func makeAudio(seconds: Double, sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-whisper-audio-\(UUID().uuidString).caf")
        try TestAudio.write(
            to: url, seconds: seconds, sampleRate: sampleRate, channels: channels
        ) { _, _ in 0.25 }
        return url
    }
}

private struct RuntimeFixtureError: Error {}

private actor FailingWhisperRuntime: WhisperRuntime {
    func prepare(model: URL) async throws {}
    func transcribe(
        samples: [Float], language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        throw RuntimeFixtureError()
    }
    func release() async {}
}

private actor RecordingWhisperRuntime: WhisperRuntime {
    private(set) var languages: [String?] = []
    private(set) var sampleCounts: [Int] = []

    func prepare(model: URL) async throws {}

    func transcribe(
        samples: [Float],
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        languages.append(language)
        sampleCounts.append(samples.count)
        progress(1)
        return [.init(start: 0, end: Double(samples.count) / 16_000, text: "chunk")]
    }

    func release() async {}
}

private actor TimedWhisperRuntime: WhisperRuntime {
    private(set) var modes: [Bool] = []

    func prepare(model: URL) async throws {}

    func transcribe(
        samples: [Float], language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        Issue.record("word mode should use the timed runtime call")
        return []
    }

    func transcribe(
        samples: [Float], language: String?, wordTimings: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        modes.append(wordTimings)
        let end = Double(samples.count) / 16_000
        return [WhisperRuntimeSegment(start: 0, end: end, text: "chunk",
            words: [TranscriptWord(start: 0, end: end, text: "chunk")])]
    }

    func release() async {}
}
