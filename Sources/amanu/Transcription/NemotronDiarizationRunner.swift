import AVFoundation
import Darwin
import Foundation

/// Runs the pinned NeMo diarizer in an isolated child. The owning engine keeps
/// the verified model leased for the whole call; this value never owns a lease.
struct NemotronDiarizationRunner: Sendable {
    enum Failure: Error, Equatable, Sendable {
        case invalidAudio
        case invalidModel
        case invalidOutput
        case nativeFailure
    }

    private struct NativeResult: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let speaker: Int
        }
        let segments: [Segment]
    }

    let model: URL
    let executable: URL

    /// In a bundle, never fall back to a developer checkout's helper.
    static var bundledExecutable: URL? {
        let candidate: URL
        if let bundle = Runtime.appBundle {
            candidate = bundle.bundleURL.appendingPathComponent(
                "Contents/Helpers/NeMoSpeech/bin/nemo-speech")
        } else {
            let repository = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Transcription
                .deletingLastPathComponent() // amanu
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // repository
            candidate = repository.appendingPathComponent(".build/nemotron/bin/nemo-speech")
        }
        return isExecutable(candidate) ? candidate : nil
    }

    init(model: URL, executable: URL? = nil) throws {
        guard model.isFileURL else { throw Failure.invalidModel }
        guard let selected = executable ?? Self.bundledExecutable,
              Self.isExecutable(selected)
        else { throw LocalDiarizationRuntimeError.unavailable }
        self.model = model
        self.executable = selected
    }

    func diarize(_ audio: URL) async throws -> [SpeakerTurn] {
        try Task.checkCancellation()
        guard Self.isReadableRegularFile(model) else { throw Failure.invalidModel }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-nemotron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let wav = scratch.appendingPathComponent("source.wav")
        let duration = try Self.writeWAV(from: audio, to: wav)
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("model-cache", isDirectory: true),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("NEMO_SPEECH_") && !$0.key.hasPrefix("GGML_")
        }
        environment["NEMO_SPEECH_MODEL_INDEX"] = scratch
            .appendingPathComponent("missing-model-index.json").path
        environment["NEMO_SPEECH_MODEL_DIR"] = scratch
            .appendingPathComponent("model-cache").path

        try Task.checkCancellation()
        let result: Subprocess.Output
        do {
            result = try await Subprocess.run(
                executable: executable.path,
                arguments: ["diarize", wav.path, "--model", model.path,
                            "--device", "metal", "--preset", "v3-offline",
                            "--format", "json"],
                input: Data(), timeout: max(180, min(3_600, duration * 2)),
                environment: environment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The native process may print audio paths or detailed diagnostics.
            // Neither its stderr nor a Process launch error belongs in UI state.
            throw Failure.nativeFailure
        }
        try Task.checkCancellation()
        guard result.status == 0 else { throw Failure.nativeFailure }
        guard let native = try? JSONDecoder().decode(NativeResult.self, from: result.stdout)
        else { throw Failure.invalidOutput }
        guard !native.segments.isEmpty else {
            throw LocalDiarizationRuntimeError.noSpeechDetected
        }
        return try native.segments.map { segment in
            // One final model frame can extend past the input. Do not shift
            // starts, merge overlaps, or silently accept larger overflows.
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.start < duration,
                  segment.end > segment.start, segment.end <= duration + 0.1,
                  (1...8).contains(segment.speaker)
            else { throw Failure.invalidOutput }
            return SpeakerTurn(
                speakerID: "speaker_\(segment.speaker)",
                start: segment.start, end: min(segment.end, duration))
        }
    }

    private static func isReadableRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func isExecutable(_ url: URL) -> Bool {
        isReadableRegularFile(url) && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Stream the prepared float CAF into a classic 44-byte PCM16 RIFF file.
    /// The sample count, not a container duration rounded to milliseconds,
    /// remains the clock used to validate native intervals.
    private static func writeWAV(from source: URL, to destination: URL) throws -> Double {
        guard source.isFileURL, isReadableRegularFile(source),
              let input = try? AVAudioFile(forReading: source),
              input.length > 0,
              input.processingFormat.sampleRate == 16_000,
              input.processingFormat.channelCount == 1,
              input.processingFormat.commonFormat == .pcmFormatFloat32,
              input.length <= Int64((UInt32.max - 36) / 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                             frameCapacity: 16_384)
        else { throw Failure.invalidAudio }

        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure.invalidAudio }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }

        let byteCount = UInt32(input.length * 2)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + byteCount, to: &header)
        header.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &header) // PCM format chunk size.
        append(UInt16(1), to: &header)  // Linear PCM.
        append(UInt16(1), to: &header)  // One channel.
        append(UInt32(16_000), to: &header)
        append(UInt32(32_000), to: &header)
        append(UInt16(2), to: &header)
        append(UInt16(16), to: &header)
        header.append(contentsOf: "data".utf8)
        append(byteCount, to: &header)
        try output.write(contentsOf: header)

        var written: Int64 = 0
        while written < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(
                min(16_384, input.length - written)))
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0]
            else { throw Failure.invalidAudio }
            var pcm = Data(capacity: Int(buffer.frameLength) * 2)
            for index in 0..<Int(buffer.frameLength) {
                let value = samples[index]
                guard value.isFinite else { throw Failure.invalidAudio }
                let scaled = Int32((Double(max(-1, min(1, value))) * 32_768).rounded())
                append(UInt16(bitPattern: Int16(clamping: scaled)), to: &pcm)
            }
            try output.write(contentsOf: pcm)
            written += Int64(buffer.frameLength)
        }
        guard written == input.length else { throw Failure.invalidAudio }
        return Double(written) / 16_000
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
