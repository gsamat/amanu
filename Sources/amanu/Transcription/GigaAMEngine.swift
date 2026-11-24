import CTranscribe
import Foundation

protocol GigaAMRuntime: Sendable {
    func prepare(model: URL) async throws
    func transcribe(samples: [Float]) async throws -> String
    func release() async
}

/// Russian local transcription through Handy's transcribe.cpp GigaAM port.
/// GigaAM was trained on utterances up to about 25 seconds, so meeting tracks
/// are decoded and processed as bounded 20-second pieces.
actor GigaAMEngine: TranscriptionEngine {
    enum Progress: Equatable, Sendable {
        case downloading(GigaAMModelStore.Progress)
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
            case .invalidChunkDuration: return "GigaAM chunk duration must be greater than zero"
            }
        }
    }

    nonisolated let name = "gigaam"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .perTrack

    private let modelStore: GigaAMModelStore
    private let runtime: any GigaAMRuntime
    private let languagePolicy: TranscriptionLanguagePolicy
    private let maximumSamples: Int
    private let progress: @Sendable (Progress) -> Void

    init(
        modelStore: GigaAMModelStore = .init(),
        runtime: any GigaAMRuntime = GigaAMCPPRuntime(),
        chunkDuration: TimeInterval = 20,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) {
        self.modelStore = modelStore
        self.runtime = runtime
        languagePolicy = Config.transcriptionLanguagePolicy(for: "gigaam")
        maximumSamples = Int((chunkDuration * 16_000).rounded())
        self.progress = progress
        model = modelStore.manifest.id
    }

    func prepare() async throws {
        try languagePolicy.validate(engine: name, model: model)
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

        var result: [TranscriptSegment] = []
        var processed = 0
        while true {
            let samples: [Float]
            do {
                guard let next = try reader.nextChunk() else { break }
                samples = next
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw EngineError.unreadableAudio(audio, error)
            }
            try Task.checkCancellation()
            let start = Double(processed) / 16_000
            let text = try await runtime.transcribe(samples: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            processed += samples.count
            if !text.isEmpty {
                result.append(.init(
                    start: start,
                    end: Double(processed) / 16_000,
                    text: text))
            }
            let total = max(reader.estimatedSampleCount, processed)
            progress(.transcribing(min(1, Double(processed) / Double(total))))
        }
        progress(.transcribing(1))
        return result
    }

    func release() async { await runtime.release() }
}

private final class GigaAMCPPRuntime: GigaAMRuntime, @unchecked Sendable {
    enum RuntimeError: Swift.Error, CustomStringConvertible {
        case openFailed(String)
        case notPrepared
        case runFailed(String)

        var description: String {
            switch self {
            case .openFailed(let message): return "transcribe.cpp could not load GigaAM: \(message)"
            case .notPrepared: return "GigaAM used before prepare()"
            case .runFailed(let message): return "GigaAM transcription failed: \(message)"
            }
        }
    }

    private let lock = NSLock()
    private var session: OpaquePointer?

    func prepare(model: URL) async throws {
        try await DedicatedThread.run("gigaam load") { [self] in try load(model) }
    }

    private func load(_ model: URL) throws {
        try lock.withLock {
            if session != nil { return }
            var opened: OpaquePointer?
            let status = model.path.withCString {
                transcribe_open($0, nil, nil, &opened)
            }
            guard status == TRANSCRIBE_OK, let opened else {
                throw RuntimeError.openFailed(Self.message(status))
            }
            session = opened
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        let state = GigaAMRunState()
        return try await withTaskCancellationHandler {
            try await DedicatedThread.run("gigaam") { [self] in try decode(samples, state) }
        } onCancel: {
            state.cancel()
        }
    }

    private func decode(_ samples: [Float], _ state: GigaAMRunState) throws -> String {
        try lock.withLock {
            guard let session else { throw RuntimeError.notPrepared }
            transcribe_set_abort_callback(session, { opaque in
                guard let opaque else { return false }
                return Unmanaged<GigaAMRunState>.fromOpaque(opaque)
                    .takeUnretainedValue().cancelled
            }, Unmanaged.passUnretained(state).toOpaque())
            defer { transcribe_set_abort_callback(session, nil, nil) }
            var params = transcribe_run_params()
            transcribe_run_params_init(&params)
            params.language = nil
            let status = samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
            if status == TRANSCRIBE_ERR_ABORTED { throw CancellationError() }
            guard status == TRANSCRIBE_OK else {
                throw RuntimeError.runFailed(Self.message(status))
            }
            guard let text = transcribe_full_text(session) else { return "" }
            return String(cString: text)
        }
    }

    func release() async {
        lock.withLock {
            transcribe_session_free(session)
            session = nil
        }
    }

    private static func message(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}

private final class GigaAMRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
