import AVFoundation
import Foundation
import whisper

struct WhisperRuntimeSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

protocol WhisperRuntime: Sendable {
    func prepare(model: URL) async throws
    func transcribe(
        samples: [Float],
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment]
    func release() async
}

/// Local large-v3-turbo transcription through the official whisper.cpp C API.
/// Audio and recognition are deliberately chunked: neither decoding nor the
/// `[Float]` passed into C grows with a meeting's duration.
actor WhisperEngine: TranscriptionEngine {
    enum Progress: Equatable, Sendable {
        case downloading(WhisperModelStore.Progress)
        case transcribing(Double)
    }

    enum EngineError: Swift.Error, TranscriptionFailure, CustomStringConvertible {
        case unreadableAudio(URL, Swift.Error?)
        case invalidChunkDuration

        var isPermanent: Bool {
            switch self {
            case .unreadableAudio: return true
            case .invalidChunkDuration: return false
            }
        }

        var description: String {
            switch self {
            case .unreadableAudio(let url, let error):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (error.map { ": \($0)" } ?? "")
            case .invalidChunkDuration: return "whisper chunk duration must be greater than zero"
            }
        }
    }

    nonisolated let name = "whisper.cpp"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .perTrack

    private let modelStore: WhisperModelStore
    private let runtime: any WhisperRuntime
    private let language: String?
    private let maximumSamples: Int
    private let progress: @Sendable (Progress) -> Void

    init(
        modelStore: WhisperModelStore = .init(),
        runtime: any WhisperRuntime = WhisperCPPRuntime(),
        language: String? = nil,
        chunkDuration: TimeInterval = 10 * 60,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) {
        self.modelStore = modelStore
        self.runtime = runtime
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = trimmed?.isEmpty == false ? trimmed : nil
        maximumSamples = Int((chunkDuration * 16_000).rounded())
        self.progress = progress
        model = modelStore.manifest.id
    }

    func prepare() async throws {
        let modelURL = try await modelStore.download { [progress] update in
            progress(.downloading(update))
        }
        try await runtime.prepare(model: modelURL)
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard maximumSamples > 0 else { throw EngineError.invalidChunkDuration }
        let reader: WhisperPCMReader
        do {
            reader = try WhisperPCMReader(audio: audio, maximumSamples: maximumSamples)
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var out: [TranscriptSegment] = []
        var processedSamples = 0
        while true {
            let samples: [Float]
            do {
                guard let next = try reader.nextChunk() else { break }
                samples = next
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as EngineError {
                throw error
            } catch {
                throw EngineError.unreadableAudio(audio, error)
            }
            try Task.checkCancellation()
            let processedBeforeChunk = processedSamples
            let sampleCount = samples.count
            let chunkStart = Double(processedBeforeChunk) / 16_000
            let total = max(reader.estimatedSampleCount, processedBeforeChunk + sampleCount)
            // Failures after this boundary belong to the recognizer/model and
            // must stay retryable. Only AVFoundation failures above are bad
            // input that a persistent queue should retire permanently.
            let segments = try await runtime.transcribe(
                samples: samples,
                language: language
            ) { [progress] fraction in
                let completed = Double(processedBeforeChunk) + Double(sampleCount) * fraction
                progress(.transcribing(min(1, completed / Double(total))))
            }
            out += segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                // Whisper's failure on quiet audio is a loop rather than
                // silence: one short phrase said over and over until the
                // window is full. A phrase that many repeats inside a single
                // segment is not something anybody said.
                guard !Self.isRepetitionLoop(text) else { return nil }
                return TranscriptSegment(
                    start: chunkStart + segment.start,
                    end: chunkStart + segment.end,
                    text: text)
            }
            processedSamples += samples.count
        }
        progress(.transcribing(1))
        return out
    }

    func release() async {
        await runtime.release()
    }

    /// Whether a segment is whisper looping on quiet audio rather than
    /// transcribing speech: one short phrase said over and over until the
    /// window is full — "put it in the middle of the middle of the middle" —
    /// once per 30-second window when the microphone carried nothing
    /// intelligible. Real speech repeats words, but rarely the same two-word
    /// phrase four times inside a single segment, and when it does, the
    /// segment is not worth keeping anyway.
    static func isRepetitionLoop(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 6 else { return false }
        for length in 1...3 {
            var counts: [String: Int] = [:]
            for start in 0...(words.count - length) {
                let gram = words[start..<(start + length)].joined(separator: " ")
                counts[gram, default: 0] += 1
            }
            if let repeats = counts.values.max(), repeats >= 4 { return true }
        }
        return false
    }
}

/// Sequential AVFoundation conversion into fixed-size mono float buffers.
/// The converter owns at most one input buffer and one output chunk at once.
final class WhisperPCMReader {
    static let sampleRate: Double = 16_000

    let estimatedSampleCount: Int
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputFormat: AVAudioFormat
    private let maximumSamples: Int
    private var reachedEnd = false

    init(audio: URL, maximumSamples: Int) throws {
        guard maximumSamples > 0 else { throw WhisperEngine.EngineError.invalidChunkDuration }
        file = try AVAudioFile(forReading: audio)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw WhisperEngine.EngineError.unreadableAudio(audio, nil)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: format),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(32_768))
        else { throw WhisperEngine.EngineError.unreadableAudio(audio, nil) }
        outputFormat = format
        self.converter = converter
        inputBuffer = buffer
        self.maximumSamples = maximumSamples
        estimatedSampleCount = Int((Double(file.length) * Self.sampleRate
            / file.processingFormat.sampleRate).rounded())
    }

    func nextChunk() throws -> [Float]? {
        guard !reachedEnd else { return nil }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(maximumSamples))
        else { return nil }

        var conversionError: NSError?
        var readError: Swift.Error?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, state in
            // AVAudioFile throws the unhelpful `nilError` when asked to read
            // once more at exact EOF. Its frame position is the reliable EOF
            // signal, so do not make that final read.
            if file.framePosition >= file.length {
                state.pointee = .endOfStream
                return nil
            }
            do {
                let frames = min(requested, inputBuffer.frameCapacity)
                try file.read(into: inputBuffer, frameCount: frames)
                if inputBuffer.frameLength == 0 {
                    state.pointee = .endOfStream
                    return nil
                }
                state.pointee = .haveData
                return inputBuffer
            } catch {
                readError = error
                state.pointee = .endOfStream
                return nil
            }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .endOfStream { reachedEnd = true }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            reachedEnd = true
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

private final class WhisperCPPRuntime: WhisperRuntime, @unchecked Sendable {
    enum RuntimeError: Swift.Error, CustomStringConvertible {
        case modelLoadFailed(URL)
        case notPrepared
        case inferenceFailed(Int32)

        var description: String {
            switch self {
            case .modelLoadFailed(let url): return "whisper.cpp could not load \(url.lastPathComponent)"
            case .notPrepared: return "whisper.cpp used before prepare()"
            case .inferenceFailed(let code): return "whisper.cpp inference failed (\(code))"
            }
        }
    }

    private let contextLock = NSLock()
    private var context: OpaquePointer?

    func prepare(model: URL) async throws {
        try contextLock.withLock {
            if context != nil { return }
            var params = whisper_context_default_params()
            params.use_gpu = true
            context = model.path.withCString { whisper_init_from_file_with_params($0, params) }
            guard context != nil else { throw RuntimeError.modelLoadFailed(model) }
        }
    }

    func transcribe(
        samples: [Float],
        language: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [WhisperRuntimeSegment] {
        let run = WhisperRunState(progress: progress)
        return try await withTaskCancellationHandler {
            try contextLock.withLock {
                guard let context else { throw RuntimeError.notPrepared }
                var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
                params.translate = false
                params.no_context = true
                params.no_timestamps = false
                params.single_segment = false
                params.print_special = false
                params.print_progress = false
                params.print_realtime = false
                params.print_timestamps = false
                params.token_timestamps = false
                params.progress_callback = { _, _, percentage, opaque in
                    guard let opaque else { return }
                    Unmanaged<WhisperRunState>.fromOpaque(opaque)
                        .takeUnretainedValue().report(Double(percentage) / 100)
                }
                params.progress_callback_user_data = Unmanaged.passUnretained(run).toOpaque()
                params.abort_callback = { opaque in
                    guard let opaque else { return false }
                    return Unmanaged<WhisperRunState>.fromOpaque(opaque)
                        .takeUnretainedValue().isCancelled
                }
                params.abort_callback_user_data = Unmanaged.passUnretained(run).toOpaque()

                let code: Int32 = samples.withUnsafeBufferPointer { pcm in
                    if let language {
                        return language.withCString { value in
                            params.language = value
                            return whisper_full(context, params, pcm.baseAddress, Int32(pcm.count))
                        }
                    }
                    return "auto".withCString { value in
                        params.language = value
                        return whisper_full(context, params, pcm.baseAddress, Int32(pcm.count))
                    }
                }
                try Task.checkCancellation()
                guard code == 0 else { throw RuntimeError.inferenceFailed(code) }

                return (0..<Int(whisper_full_n_segments(context))).compactMap { index in
                    guard let bytes = whisper_full_get_segment_text(context, Int32(index)) else {
                        return nil
                    }
                    return WhisperRuntimeSegment(
                        start: Double(whisper_full_get_segment_t0(context, Int32(index))) / 100,
                        end: Double(whisper_full_get_segment_t1(context, Int32(index))) / 100,
                        text: String(cString: bytes))
                }
            }
        } onCancel: {
            run.cancel()
        }
    }

    func release() async {
        contextLock.withLock {
            if let context { whisper_free(context) }
            context = nil
        }
    }

    deinit {
        contextLock.withLock {
            if let context { whisper_free(context) }
        }
    }
}

private final class WhisperRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var cancelled = false

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func report(_ value: Double) { progress(min(1, max(0, value))) }
}
