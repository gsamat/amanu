import AVFoundation
import Foundation
import os
import Testing

@testable import amanu

/// The cloud engines against a service that answers whatever the test says.
///
/// Every one of these used to be reachable only with a key, a network and a
/// bill: a revoked key retried at every launch, a 503 during a three-hour
/// poll that threw away a paid job, a response nobody could decode.
struct CloudHTTPTests {
    // MARK: - classification

    @Test("Statuses are sorted into key problems, refusals and passing trouble")
    func statusClassification() {
        #expect(CloudHTTP.classify(status: 200) == .success)
        #expect(CloudHTTP.classify(status: 401) == .unauthorized)
        #expect(CloudHTTP.classify(status: 403) == .unauthorized)
        #expect(CloudHTTP.classify(status: 400) == .rejected)
        #expect(CloudHTTP.classify(status: 413) == .rejected)
        #expect(CloudHTTP.classify(status: 429) == .retryable)
        #expect(CloudHTTP.classify(status: 500) == .retryable)
        #expect(CloudHTTP.classify(status: 503) == .retryable)
    }

    @Test("Retry-After is read in seconds and as a date")
    func retryAfterForms() throws {
        let url = URL(string: "https://example.test")!
        let seconds = try #require(HTTPURLResponse(
            url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"]))
        #expect(CloudHTTP.retryAfter(seconds) == .seconds(7))

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = try #require(HTTPURLResponse(
            url: url, statusCode: 503, httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: now.addingTimeInterval(30))]))
        #expect(CloudHTTP.retryAfter(date, now: now) == .seconds(30))
    }

    // MARK: - AssemblyAI end to end

    @Test("A refused key fails at once, is not the recording's fault, and uploads once")
    func unauthorizedIsEnvironmental() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { _, _ in .json(401, #"{"error":"Invalid API key"}"#) }
        let engine = try fixture.engine(stub)

        let error = await #expect(throws: CloudHTTP.Failure.self) {
            try await engine.transcribe(fixture.audio)
        }
        #expect(error?.isEnvironmental == true)
        #expect(error?.isPermanent == false)
        #expect(stub.requests(to: "/v2/upload").count == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test("A request the service rejects is permanent and is not asked again")
    func rejectionIsPermanent() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { _, _ in .json(413, #"{"error":"too large"}"#) }
        let engine = try fixture.engine(stub)

        let error = await #expect(throws: CloudHTTP.Failure.self) {
            try await engine.transcribe(fixture.audio)
        }
        #expect(error?.isPermanent == true)
        #expect(stub.requests(to: "/v2/upload").count == 1)
    }

    @Test("429 waits as long as the service asked before asking again")
    func tooManyRequestsHonoursRetryAfter() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, count in
            if request.path == "/v2/transcript", request.method == "POST", count == 1 {
                return .json(429, "{}", headers: ["Retry-After": "7"])
            }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)

        let segments = try await engine.transcribe(fixture.audio)

        #expect(segments.map(\.text) == ["hello from the far end"])
        #expect(fixture.sleeps.first == .seconds(7))
        #expect(stub.requests(to: "/v2/transcript").count == 2)
    }

    @Test("A server error is retried with a growing pause, and fails as passing trouble")
    func serverErrorsBackOffThenGiveUp() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { _, _ in .json(503, "busy") }
        let engine = try fixture.engine(stub)

        let error = await #expect(throws: CloudHTTP.Failure.self) {
            try await engine.transcribe(fixture.audio)
        }
        #expect(error?.isPermanent == false)
        #expect(error?.isEnvironmental == false)
        #expect(stub.requests(to: "/v2/upload").count == 4)
        #expect(fixture.sleeps == [.seconds(2), .seconds(4), .seconds(8)])
    }

    @Test("A body that is not the documented JSON is called malformed, not a crash")
    func malformedBody() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { _, _ in .status(200, body: Data("<html>captive portal</html>".utf8)) }
        let engine = try fixture.engine(stub)

        let error = await #expect(throws: CloudHTTP.Failure.self) {
            try await engine.transcribe(fixture.audio)
        }
        guard case .malformed = error else {
            Issue.record("expected a malformed-response failure, got \(String(describing: error))")
            return
        }
    }

    @Test("A transcript the service failed is reported, and its job forgotten")
    func transcriptErrorForgetsTheJob() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-1" {
                return .json(200, #"{"status":"error","error":"Transcoding failed"}"#)
            }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)

        await #expect(throws: AssemblyAIEngine.EngineError.self) {
            try await engine.transcribe(fixture.audio)
        }
        #expect(fixture.jobFiles.isEmpty)
    }

    @Test("A poll that fails for a while is sat out rather than paid for again")
    func pollToleratesTransientFailures() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, count in
            if request.path == "/v2/transcript/job-1" {
                switch count {
                case 1: return .failure(.networkConnectionLost)
                case 2: return .json(503, "busy")
                case 3: return .failure(.notConnectedToInternet)
                case 4: return .json(200, #"{"status":"processing"}"#)
                default: break
                }
            }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)

        let segments = try await engine.transcribe(fixture.audio)

        #expect(segments.count == 1)
        #expect(stub.requests(to: "/v2/upload").count == 1)
        #expect(stub.requests(to: "/v2/transcript/job-1").count == 5)
    }

    @Test("A job still running when the attempt stops waiting is resumed, not uploaded again")
    func timedOutJobIsResumed() async throws {
        let fixture = try Fixture()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-1", !finished.withLock({ $0 }) {
                return .json(200, #"{"status":"processing"}"#)
            }
            return Fixture.happyPath(request)
        }
        let impatient = try fixture.engine(
            stub, timing: .init(pollInterval: .milliseconds(5), pollTimeout: 0.05))

        await #expect(throws: AssemblyAIEngine.EngineError.self) {
            try await impatient.transcribe(fixture.audio)
        }
        #expect(fixture.jobFiles.count == 1)

        finished.withLock { $0 = true }
        let segments = try await fixture.engine(stub).transcribe(fixture.audio)

        #expect(segments.map(\.text) == ["hello from the far end"])
        #expect(stub.requests(to: "/v2/upload").count == 1)
        #expect(fixture.jobFiles.isEmpty)
    }

    @Test("A job the service no longer knows is submitted again")
    func vanishedJobIsResubmitted() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-gone" { return .json(404, "{}") }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)
        try JSONSerialization.data(withJSONObject: ["id": "job-gone"])
            .write(to: await fixture.jobFile(for: engine))

        let segments = try await engine.transcribe(fixture.audio)

        #expect(segments.count == 1)
        #expect(stub.requests(to: "/v2/upload").count == 1)
    }

    /// A job belongs to the key that submitted it. With a new key the
    /// service answers 401 about it, which is "the machine's fault" — so the
    /// session was held for ever over a job only the old key could see.
    @Test("A job submitted with another key is dropped, and a new one submitted")
    func jobFromAnotherKeyIsResubmitted() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-old" { return .json(401, "{}") }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)
        try JSONSerialization.data(withJSONObject: [
            "id": "job-old", "key": AssemblyAIEngine.digest(of: "the-old-key"),
        ]).write(to: await fixture.jobFile(for: engine))

        let segments = try await engine.transcribe(fixture.audio)

        #expect(segments.count == 1)
        #expect(stub.requests(to: "/v2/transcript/job-old").isEmpty,
                "the old key's job was asked about with the new key")
        #expect(stub.requests(to: "/v2/upload").count == 1)
    }

    @Test("A resumed job the service refuses to show is taken for gone",
          arguments: [401, 403])
    func refusedResumeIsResubmitted(status: Int) async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-hidden" { return .json(status, "{}") }
            return Fixture.happyPath(request)
        }
        let engine = try fixture.engine(stub)
        // Written before the key was recorded beside the id.
        try JSONSerialization.data(withJSONObject: ["id": "job-hidden"])
            .write(to: await fixture.jobFile(for: engine))

        let segments = try await engine.transcribe(fixture.audio)

        #expect(segments.count == 1)
        #expect(stub.requests(to: "/v2/transcript/job-hidden").count == 1)
        #expect(stub.requests(to: "/v2/upload").count == 1)
    }

    @Test("The job file records which key submitted it")
    func jobRecordsItsKey() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-1" {
                return .json(200, #"{"status":"processing"}"#)
            }
            return Fixture.happyPath(request)
        }
        let impatient = try fixture.engine(
            stub, timing: .init(pollInterval: .milliseconds(5), pollTimeout: 0.02))
        await #expect(throws: AssemblyAIEngine.EngineError.self) {
            try await impatient.transcribe(fixture.audio)
        }
        let file = try #require(fixture.jobFiles.first)
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["id"] as? String == "job-1")
        #expect(json["key"] as? String == AssemblyAIEngine.digest(of: "test-key"))
        #expect(!(String(decoding: try Data(contentsOf: file), as: UTF8.self)).contains("test-key"))
    }

    @Test("Cancelling a poll stops it at once and keeps the job for next time")
    func cancellationKeepsTheJob() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in
            if request.path == "/v2/transcript/job-1" {
                return .json(200, #"{"status":"processing"}"#)
            }
            return Fixture.happyPath(request)
        }
        let engine = try AssemblyAIEngine(
            apiKey: "test-key", session: stub.session,
            timing: .init(pollInterval: .milliseconds(20)))

        let task = Task { try await engine.transcribe(fixture.audio) }
        while stub.requests(to: "/v2/transcript/job-1").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.jobFiles.count == 1)
    }

    /// A file AVFoundation could not open used to be taken for mono: the
    /// upload went ahead without `multichannel`, and the labels that came
    /// back were bare letters with no side in them.
    @Test("Audio that cannot be opened is refused before anything is uploaded")
    func unreadableAudioIsNotGuessedMono() async throws {
        let fixture = try Fixture()
        let notAudio = fixture.dir.appendingPathComponent("multichannel.m4a")
        try Data("not audio at all".utf8).write(to: notAudio)
        let stub = StubHTTP { request, _ in Fixture.happyPath(request) }

        await #expect(throws: (any Error).self) {
            try await fixture.engine(stub).transcribe(notAudio)
        }
        #expect(stub.requests.isEmpty)
    }

    @Test("A completed response is reused without a single request")
    func cacheIsReused() async throws {
        let fixture = try Fixture()
        let stub = StubHTTP { request, _ in Fixture.happyPath(request) }
        _ = try await fixture.engine(stub).transcribe(fixture.audio)
        let before = stub.requests.count

        let again = try await fixture.engine(stub).transcribe(fixture.audio)

        #expect(again.map(\.text) == ["hello from the far end"])
        #expect(stub.requests.count == before)
    }

    @Test("The key goes out under each service's own header")
    func keysUseEachServicesHeader() async throws {
        let stub = StubHTTP { _, _ in .json(200, "{}") }
        for service in CloudService.allCases {
            _ = try await CloudHTTP(service: service, session: stub.session)
                .send(URLRequest(url: URL(string: "https://example.test/\(service.rawValue)")!),
                      key: "secret", what: "probe")
        }
        let headers = stub.requests.map { ($0.header("authorization"), $0.header("xi-api-key")) }
        #expect(headers.map(\.0) == ["secret", "Bearer secret", nil])
        #expect(headers.map(\.1) == [nil, nil, "secret"])
    }

    // MARK: -

    /// One mono recording in a folder of its own, and a record of every
    /// pause the engine asked for instead of taking it.
    private struct Fixture {
        let dir: URL
        let audio: URL
        private let slept = OSAllocatedUnfairLock(initialState: [Duration]())

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("amanu-cloud-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            audio = dir.appendingPathComponent("multichannel.caf")
            try Self.stereo(audio, seconds: 1, channels: 1)
        }

        var sleeps: [Duration] { slept.withLock { $0 } }

        var jobFiles: [URL] {
            ProviderCache.files(in: dir).filter { $0.lastPathComponent.hasSuffix(".job.json") }
        }

        func jobFile(for engine: AssemblyAIEngine) async -> URL {
            await engine.cacheURL(for: audio, multichannel: false)
                .deletingPathExtension().appendingPathExtension("job.json")
        }

        func engine(
            _ stub: StubHTTP, timing: AssemblyAIEngine.Timing = .init(pollInterval: .zero)
        ) throws -> AssemblyAIEngine {
            let slept = slept
            return try AssemblyAIEngine(
                apiKey: "test-key", session: stub.session, timing: timing,
                sleep: { duration in
                    slept.withLock { $0.append(duration) }
                    // Pauses a test chose to be short are taken, so a poll
                    // with a deadline does not spin; the rest are only noted.
                    if duration > .zero, duration < .milliseconds(100) {
                        try await Task.sleep(for: duration)
                    }
                    try Task.checkCancellation()
                })
        }

        /// What the service says when nothing is wrong.
        static func happyPath(_ request: StubHTTP.Request) -> StubHTTP.Reply {
            switch (request.method, request.path) {
            case ("POST", "/v2/upload"):
                return .json(200, #"{"upload_url":"https://cdn.example.test/audio"}"#)
            case ("POST", "/v2/transcript"):
                return .json(200, #"{"id":"job-1"}"#)
            case ("GET", _) where request.path.hasPrefix("/v2/transcript/"):
                return .json(200, """
                {"status":"completed","text":"hello from the far end","utterances":[
                  {"speaker":"2A","text":"hello from the far end","start":100,"end":900}]}
                """)
            default:
                return .json(404, "{}")
            }
        }

        private static func stereo(_ url: URL, seconds: Double, channels: AVAudioChannelCount = 2) throws {
            let rate = 16_000.0
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
            let file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormats.pcmSettings(sampleRate: rate, channels: channels),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let frames = AVAudioFrameCount(seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(channels) {
                for i in 0..<Int(frames) {
                    buffer.floatChannelData![channel][i] = 0.2 * Float(sin(Double(i) * 0.05))
                }
            }
            try file.write(from: buffer)
        }
    }
}
