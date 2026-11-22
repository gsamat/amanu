import AVFoundation
import Foundation
import Testing
@testable import amanu

@Suite(.timeLimit(.minutes(1)))
struct NemotronDiarizationRunnerTests {
    @Test("Converts prepared CAF to private mono PCM16 WAV and keeps overlapping native turns")
    func convertsAndPreservesOverlap() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try preparedCAF(in: directory)
        let model = try dummyModel(in: directory)
        let copy = directory.appendingPathComponent("captured.wav")
        let args = directory.appendingPathComponent("args.txt")
        let environment = directory.appendingPathComponent("environment.txt")
        let helper = try fakeHelper(in: directory, body: """
        cp "$2" "\(copy.path)"
        printf '%s\\n' "$@" > "\(args.path)"
        printf '%s\\n' "${NEMO_SPEECH_MODEL_INDEX-}" "${NEMO_SPEECH_MODEL_DIR-}" "${NEMO_SPEECH_DIAR_ONSET-unset}" "${GGML_LOG_LEVEL-unset}" > "\(environment.path)"
        cat <<'JSON'
        {"segments":[{"start":0.125,"end":0.75,"speaker":1},{"start":0.5,"end":1.008,"speaker":2}]}
        JSON
        """)

        let turns = try await NemotronDiarizationRunner(model: model, executable: helper).diarize(audio)
        #expect(turns == [
            SpeakerTurn(speakerID: "speaker_1", start: 0.125, end: 0.75),
            SpeakerTurn(speakerID: "speaker_2", start: 0.5, end: 1.0),
        ])
        let data = try Data(contentsOf: copy)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        let wav = try AVAudioFile(forReading: copy)
        #expect(wav.length == 16_000)
        #expect(wav.processingFormat.channelCount == 1)
        #expect(wav.processingFormat.sampleRate == 16_000)
        #expect(wav.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let argv = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv.first == "diarize")
        #expect(argv.contains("--model") && argv.contains(model.path))
        #expect(argv.contains("--device") && argv.contains("metal"))
        #expect(argv.contains("--preset") && argv.contains("v3-offline"))
        #expect(argv.contains("--format") && argv.contains("json"))
        #expect(!argv.contains("--output"))
        let privateWAV = try #require(argv.dropFirst().first)
        #expect(!FileManager.default.fileExists(atPath: privateWAV))
        let controls = try String(contentsOf: environment, encoding: .utf8).split(separator: "\n")
        #expect(controls.count == 4)
        #expect(controls[0].contains("amanu-nemotron-"))
        #expect(!FileManager.default.fileExists(atPath: String(controls[0])))
        #expect(controls[1].contains("amanu-nemotron-"))
        #expect(controls[2] == "unset")
        #expect(controls[3] == "unset")
    }

    @Test("Empty native activity becomes no-speech, not a successful empty diarization")
    func emptyOutput() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try fakeHelper(in: directory, body: "echo '{\"segments\":[]}'")
        let runner = try NemotronDiarizationRunner(
            model: try dummyModel(in: directory), executable: helper)
        let audio = try preparedCAF(in: directory)
        await #expect(throws: LocalDiarizationRuntimeError.noSpeechDetected) {
            try await runner.diarize(audio)
        }
    }

    @Test("Malformed, nonfinite, invalid-speaker and out-of-range results fail closed")
    func invalidNativeOutput() async throws {
        let samples = [
            "not-json",
            "{\"segments\":[{\"start\":0.0,\"end\":0.4,\"speaker\":0}]}",
            "{\"segments\":[{\"start\":0.0,\"end\":0.4,\"speaker\":9}]}",
            "{\"segments\":[{\"start\":0.5,\"end\":0.5,\"speaker\":1}]}",
            "{\"segments\":[{\"start\":-0.1,\"end\":0.4,\"speaker\":1}]}",
            "{\"segments\":[{\"start\":0.0,\"end\":1.25,\"speaker\":1}]}",
            "{\"segments\":[{\"start\":1e999,\"end\":1e999,\"speaker\":1}]}",
        ]
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try preparedCAF(in: directory)
        let model = try dummyModel(in: directory)
        for (index, sample) in samples.enumerated() {
            let helper = try fakeHelper(in: directory, name: "helper-\(index)", body: """
            cat <<'JSON'
            \(sample)
            JSON
            """)
            let runner = try NemotronDiarizationRunner(model: model, executable: helper)
            await #expect(throws: NemotronDiarizationRunner.Failure.invalidOutput,
                          "Invalid native output \(index) must fail as invalidOutput") {
                try await runner.diarize(audio)
            }
        }
    }

    @Test("Child diagnostics stay out of errors shown to callers")
    func privateChildError() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try fakeHelper(in: directory, body: "echo 'PRIVATE_CHILD_DETAIL' >&2; exit 7")
        let runner = try NemotronDiarizationRunner(
            model: try dummyModel(in: directory), executable: helper)
        let audio = try preparedCAF(in: directory)
        do {
            _ = try await runner.diarize(audio)
            Issue.record("Expected a native runtime failure")
        } catch let error as NemotronDiarizationRunner.Failure {
            #expect(error == .nativeFailure)
            #expect(!String(describing: error).contains("PRIVATE_CHILD_DETAIL"))
            #expect(!error.localizedDescription.contains("PRIVATE_CHILD_DETAIL"))
        } catch {
            Issue.record("Expected a typed native failure, got \(type(of: error))")
        }
    }

    @Test("A missing native helper is a typed unavailable condition")
    func missingHelper() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: LocalDiarizationRuntimeError.unavailable) {
            _ = try NemotronDiarizationRunner(
                model: try dummyModel(in: directory),
                executable: directory.appendingPathComponent("absent"))
        }
    }

    @Test("Cancelling native processing stops its child and removes the private WAV")
    func cancelled() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("wav-path.txt")
        let helper = try fakeHelper(in: directory, body: """
        printf '%s' "$2" > "\(marker.path)"
        sleep 10
        """)
        let runner = try NemotronDiarizationRunner(
            model: try dummyModel(in: directory), executable: helper)
        let audio = try preparedCAF(in: directory)
        let task = Task { try await runner.diarize(audio) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        if FileManager.default.fileExists(atPath: marker.path) {
            let wav = try String(contentsOf: marker, encoding: .utf8)
            #expect(!FileManager.default.fileExists(atPath: wav))
        }
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-nemotron-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func dummyModel(in directory: URL) throws -> URL {
        let model = directory.appendingPathComponent("verified.gguf")
        try Data("verified by store".utf8).write(to: model)
        return model
    }

    private func preparedCAF(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("prepared.caf")
        let rate = 16_000.0
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(
            forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: rate, channels: 1),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = 0.2 }
        try file.write(from: buffer)
        return url
    }

    private func fakeHelper(in directory: URL, name: String = "helper", body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
