import AVFoundation
import Foundation
import Testing

@testable import amanu

struct WhisperRealWordTimingTests {
    private enum SmokeInputError: Error { case invalidPath }

    /// Explicit paths keep the normal suite offline and away from personal recordings.
    @Test("Pinned Whisper model emits real timed words on a permitted AMI clip",
          .enabled(if: ProcessInfo.processInfo.environment["AMANU_WHISPER_MODEL"] != nil
            && ProcessInfo.processInfo.environment["AMANU_WHISPER_AMI_AUDIO"] != nil))
    func publicAMIWordTimingSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: environment["AMANU_WHISPER_MODEL"]!)
        let audio = URL(fileURLWithPath: environment["AMANU_WHISPER_AMI_AUDIO"]!)
        let manifest = WhisperModelStore.defaultManifest
        guard model.lastPathComponent == manifest.fileName,
              FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: audio.path)
        else { throw SmokeInputError.invalidPath }
        let store = WhisperModelStore(
            directory: model.deletingLastPathComponent(), manifest: manifest) { _, _, _ in
                Issue.record("the supplied Whisper model must already be present and verified")
            }
        let engine = WhisperEngine(modelStore: store, expectedLanguages: ["en"],
                                   wordTimings: true)
        try await engine.prepare()
        let segments: [TranscriptSegment]
        do {
            segments = try await engine.transcribe(audio)
        } catch {
            await engine.release()
            throw error
        }
        await engine.release()

        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let words = segments.flatMap { $0.words ?? [] }
        let valid = words.filter {
            $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.start < $0.end
                && $0.end <= duration + 1.0 / 16_000
        }.count
        let punctuated = words.filter { word in
            word.text.unicodeScalars.contains {
                CharacterSet.punctuationCharacters.contains($0)
            }
        }.count
        print("Whisper AMI timing: segments=\(segments.count) words=\(words.count) "
            + "valid=\(valid) punctuated=\(punctuated) "
            + "withoutWords=\(segments.filter { $0.words == nil }.count)")
        #expect(!segments.isEmpty)
        #expect(!words.isEmpty)
        #expect(valid == words.count)
        #expect(punctuated > 0)
        for segment in segments {
            guard let lexical = segment.words else { continue }
            #expect(lexical.map(\.text).joined().filter { !$0.isWhitespace }
                == segment.text.filter { !$0.isWhitespace })
        }
    }
}
