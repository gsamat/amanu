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

    @Test("Chunk timestamps are relative to the original audio and language reaches whisper.cpp")
    func engineOffsetsSegmentsAndPassesLanguage() async throws {
        let audio = try makeAudio(seconds: 1.25, sampleRate: 16_000, channels: 1)
        let store = try fixtureStore()
        let runtime = RecordingWhisperRuntime()
        let engine = WhisperEngine(
            modelStore: store,
            runtime: runtime,
            language: "ru",
            chunkDuration: 0.5)

        try await engine.prepare()
        let segments = try await engine.transcribe(audio)

        #expect(engine.name == "whisper.cpp")
        #expect(engine.model == "fixture")
        #expect(WhisperEngine().model == "large-v3-turbo-q5_0")
        #expect(engine.input.metadataName == "per-track")
        #expect(await runtime.languages == ["ru", "ru", "ru"])
        #expect(await runtime.sampleCounts == [8_000, 8_000, 4_000])
        #expect(segments.map(\.start) == [0, 0.5, 1.0])
        #expect(segments.map(\.end) == [0.5, 1.0, 1.25])
        #expect(segments.allSatisfy { $0.speaker == nil })
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

    @Test("A repetition loop from a quiet microphone is dropped, real speech is kept")
    func repetitionLoopsAreDropped() async throws {
        let store = try fixtureStore()
        // The mic track of a real meeting whose first minutes carried no
        // intelligible speech: whisper said this, once per 30-second window.
        let loop = WhisperRuntimeSegment(
            start: 0, end: 7,
            text: "I'm going to go ahead and put it in the middle of the middle "
                + "of the middle of the middle of the middle.")
        let real = WhisperRuntimeSegment(start: 7, end: 9, text: "Regarding the open AI incidents.")
        let runtime = ScriptedWhisperRuntime(segments: [loop, real])
        let engine = WhisperEngine(modelStore: store, runtime: runtime, chunkDuration: 10)
        try await engine.prepare()
        let audio = try makeAudio(seconds: 10, sampleRate: 16_000, channels: 1)

        let segments = try await engine.transcribe(audio)

        #expect(segments.map(\.text) == ["Regarding the open AI incidents."])
    }

    @Test("Repetition loops are recognized whatever the phrase")
    func repetitionLoopDetection() {
        #expect(WhisperEngine.isRepetitionLoop(
            "I'm going to go ahead and put it in the middle of the middle of the middle "
                + "of the middle of the middle."))
        #expect(WhisperEngine.isRepetitionLoop(
            "так сказать так сказать так сказать так сказать"))
        #expect(!WhisperEngine.isRepetitionLoop("Regarding the open AI incidents."))
        #expect(!WhisperEngine.isRepetitionLoop("Okay. Yeah, absolutely. Yes."))
        #expect(!WhisperEngine.isRepetitionLoop("Да."))
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
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: sampleRate, channels: channels),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let frameCount = AVAudioFrameCount((seconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frameCount) { samples[frame] = 0.25 }
        }
        try file.write(from: buffer)
        return url
    }
}

private actor ScriptedWhisperRuntime: WhisperRuntime {
    let segments: [WhisperRuntimeSegment]
    init(segments: [WhisperRuntimeSegment]) { self.segments = segments }

    func prepare(model: URL) async throws {}

    func transcribe(
        samples: [Float], language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        segments
    }

    func release() async {}
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
