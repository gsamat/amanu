import Foundation
import Testing

@testable import amanu

/// The queue, and the three rules it exists to keep: nothing is sent when the
/// switch is off, nothing is lost to a restart, and nothing grows without a
/// ceiling.
///
/// Every sink here sends only when flushed, and every flush is awaited to the
/// end rather than waited on for half a second. The suite used to block a
/// thread per test on the quit-time flush while the transport it was waiting
/// for needed a thread of its own, which is why CI ran the whole suite one
/// test at a time.
@Suite("Analytics queue")
struct AnalyticsQueueTests {
    private static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending.json")
    }

    /// A transport that keeps what it was given and answers as told — after
    /// the gate opens, when there is one.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        let succeeds: Bool
        let gate: Gate?

        init(succeeds: Bool, gate: Gate? = nil) {
            self.succeeds = succeeds
            self.gate = gate
        }

        private func keep(_ body: Data) {
            lock.lock()
            bodies.append(body)
            lock.unlock()
        }

        var transport: AnalyticsSink.Transport {
            { [self] body in
                keep(body)
                await gate?.pass()
                return succeeds ? .all : .retry
            }
        }

        var sent: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    }

    private static func sink(
        store: URL,
        on: Bool = true,
        firstRun: Bool = false,
        transport: AnalyticsSink.Transport? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> AnalyticsSink {
        AnalyticsSink(
            store: store,
            transport: transport ?? { _ in .all },
            clock: clock,
            switchIsOn: { on },
            identity: { (id: "test-identity", isFirstRun: firstRun) },
            schedulesSends: false)
    }

    @Test("With the switch off nothing is buffered and nothing is sent")
    func offSendsNothing() async {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(
            store: store, on: false, firstRun: true, transport: recorder.transport)

        sink.start(surface: .app)
        sink.record(.recordingStarted, [.trigger: .text("manual")])
        await sink.flush()

        #expect(sink.bufferedCount == 0)
        #expect(recorder.sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    /// The one event nobody can fire twice: it means "this machine had no
    /// identifier", and asking for the identifier is what ends that.
    @Test("installed fires on the first run and not on the second")
    func installedIsOnce() async {
        let store = Self.scratch()
        let first = Self.sink(store: store, firstRun: true, transport: { _ in .retry })
        first.start(surface: .app)
        await first.flush()
        #expect(first.bufferedCount == 1)

        let second = Self.sink(store: store, firstRun: false, transport: { _ in .retry })
        second.start(surface: .app)
        await second.flush()
        // The one from the first run, still unsent, and nothing added.
        #expect(second.bufferedCount == 1)
    }

    @Test("What could not be sent is still there after a restart")
    func failedSendsSurviveARestart() async {
        let store = Self.scratch()
        let failing = Self.sink(store: store, transport: { _ in .retry })
        failing.start(surface: .app)
        failing.record(.recordingFinished, [.durationBucket: .text("5_15m")])
        failing.record(.transcriptFinished, [.engine: .text("parakeet")])
        await failing.flush()
        #expect(failing.bufferedCount == 2)

        let next = Self.sink(store: store, transport: { _ in .retry })
        next.start(surface: .app)
        await next.flush()
        #expect(next.bufferedCount == 2)
    }

    @Test("A successful send clears the queue")
    func successClearsTheQueue() async {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(store: store, transport: recorder.transport)
        sink.start(surface: .app)
        sink.record(.summaryFinished, [.backend: .text("ollama")])
        await sink.flush()

        #expect(sink.bufferedCount == 0)
        #expect(recorder.sent.count == 1)
    }

    /// A flush that arrives while a send is already in flight has to wait for
    /// that send, not return because `sending` is already true. The send is
    /// held open by a gate the test controls, so "still in flight" is a fact
    /// here rather than a quarter of a second somebody hoped was long enough.
    @Test("An explicit flush waits for a send that is already in flight")
    func flushWaitsForAnInflightSend() async {
        let store = Self.scratch()
        let gate = Gate()
        let recorder = Recorder(succeeds: true, gate: gate)
        let sink = Self.sink(store: store, transport: recorder.transport)
        sink.start(surface: .app)
        sink.record(.summaryFinished, [.backend: .text("ollama")])

        let first = Flag()
        sink.flush { first.raise() }
        let joined = Flag()
        sink.flush { joined.raise() }
        // `bufferedCount` waits its turn on the sink's queue, so both flushes
        // have been handled — the first started the send, the second found it
        // running — by the time it answers.
        #expect(sink.bufferedCount == 1)
        #expect(!first.isRaised && !joined.isRaised, "a flush finished before its send did")

        gate.open()
        await sink.flush()

        #expect(first.isRaised && joined.isRaised)
        #expect(sink.bufferedCount == 0)
        #expect(recorder.sent.count == 1)
    }

    /// And the flush quitting uses keeps its promise the other way: it gives
    /// up when it said it would, and what did not go is still on disk.
    @Test("Quitting waits for a send only as long as it said it would",
          .timeLimit(.minutes(1)))
    func quitDoesNotWaitForASend() async {
        let store = Self.scratch()
        let gate = Gate()
        let sink = Self.sink(store: store, transport: Recorder(succeeds: true, gate: gate).transport)
        sink.start(surface: .app)
        sink.record(.recordingFinished, [:])

        // On a thread of its own: this is the one call that blocks.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                sink.flush(waitingUpTo: 0.05)
                done.resume()
            }
        }
        #expect(sink.bufferedCount == 1, "the unsent event is kept for the next launch")

        gate.open()
        await sink.flush()
        #expect(sink.bufferedCount == 0)
    }

    @Test("A packaged version is reported once per version")
    func versionSeenIsOncePerVersion() async throws {
        let store = Self.scratch()
        let state = store.deletingLastPathComponent().appendingPathComponent("identity.json")
        _ = AnalyticsIdentity.identifier(at: state)

        func sink(version: String) -> AnalyticsSink {
            AnalyticsSink(
                store: store,
                transport: { _ in .retry },
                switchIsOn: { true },
                identity: { (id: "test-identity", isFirstRun: false) },
                appVersion: { version },
                markVersionSeen: { AnalyticsIdentity.markVersionSeen($0, at: state) },
                schedulesSends: false)
        }

        let first = sink(version: "0.4.13")
        first.start(surface: .app)
        await first.flush()
        #expect(first.bufferedCount == 1)
        let pendingData = try Data(contentsOf: store)
        let pendingJSON = try #require(
            try JSONSerialization.jsonObject(with: pendingData) as? [String: Any])
        let pending = try #require(pendingJSON["pending"] as? [[String: Any]])
        let payload = try #require(pending.first?["payload"] as? [String: Any])
        #expect(payload["name"] as? String == "version_seen")

        let same = sink(version: "0.4.13")
        same.start(surface: .app)
        await same.flush()
        #expect(same.bufferedCount == 1, "only the first sink's unsent event remains")

        let next = sink(version: "0.4.14")
        next.start(surface: .app)
        await next.flush()
        #expect(next.bufferedCount == 2)

        let data = try Data(contentsOf: state)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json["versions_seen"] as? [String] ?? []) == ["0.4.13", "0.4.14"])
        #expect(json["id"] as? String != nil, "recording a version must preserve the identity")
    }

    /// A laptop that spent a month offline should not come back with a month
    /// of events, and should not eat disk while it is away.
    @Test("The queue stops at its ceiling, dropping the oldest")
    func theQueueHasACeiling() async {
        let store = Self.scratch()
        let sink = Self.sink(store: store, transport: { _ in .retry })
        sink.start(surface: .app)
        for _ in 0..<(AnalyticsSink.capacity + 40) {
            sink.record(.recordingStarted, [.trigger: .text("manual")])
        }
        await sink.flush()
        #expect(sink.bufferedCount == AnalyticsSink.capacity)
    }

    @Test("Events older than a week are dropped rather than sent late")
    func staleEventsAreDropped() async {
        let store = Self.scratch()
        let old = Date()
        let stale = Self.sink(store: store, transport: { _ in .retry }, clock: { old })
        stale.start(surface: .app)
        stale.record(.recordingStarted, [.trigger: .text("manual")])
        await stale.flush()
        #expect(stale.bufferedCount == 1)

        let later = old.addingTimeInterval(AnalyticsSink.maximumAge + 60)
        let fresh = Self.sink(store: store, transport: { _ in .retry }, clock: { later })
        fresh.start(surface: .app)
        await fresh.flush()
        #expect(fresh.bufferedCount == 0)
    }

    /// The Umami batch shape, checked here rather than discovered in
    /// production: a body the server silently drops looks exactly like nobody
    /// using amanu.
    @Test("The body is a batch Umami can ingest")
    func theBodyIsWellFormed() async throws {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(store: store, transport: recorder.transport)
        sink.start(surface: .cli)
        sink.record(.recordingFinished, [
            .trigger: .text("calendar"),
            .durationBucket: .text("30_60m"),
            .liveUsed: .flag(true),
        ])
        await sink.flush()

        let body = try #require(recorder.sent.first)
        let batch = try #require(
            try JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        #expect(batch.count == 2)

        let identify = try #require(batch.first)
        #expect(identify["type"] as? String == "identify")
        let identifyPayload = try #require(identify["payload"] as? [String: Any])
        #expect(identifyPayload["id"] as? String == "test-identity")
        #expect(identifyPayload["website"] as? String != nil)
        #expect(identifyPayload["timestamp"] as? Double != nil)
        #expect(identifyPayload["data"] == nil)

        let event = try #require(batch.last)
        #expect(event["type"] as? String == "event")

        let payload = try #require(event["payload"] as? [String: Any])
        #expect(payload["hostname"] as? String == "app.amanu.me")
        #expect(payload["url"] as? String == "/")
        #expect(payload["name"] as? String == "recording_finished")
        #expect(payload["id"] as? String == "test-identity")
        #expect(payload["website"] as? String != nil)
        #expect(payload["timestamp"] as? Double != nil)
        // Umami 3.3 accepts this value in the HTTP header but rejects a
        // macOS User-Agent override inside the payload.
        #expect(payload["userAgent"] == nil)

        let data = try #require(payload["data"] as? [String: Any])
        #expect(data["trigger"] as? String == "calendar")
        #expect(data["duration_bucket"] as? String == "30_60m")
        #expect(data["live_used"] as? Bool == true)
        #expect(data["surface"] as? String == "cli")
        #expect(data["macos_version"] as? String != nil)
        #expect(data["analytics_schema_version"] as? Int == 2)
        #expect(data["transcription_enabled"] as? Bool != nil)
        #expect(data["transcription_cloud_provider"] as? String != nil)
        #expect(data["summary_enabled"] as? Bool != nil)
        #expect(data["speaker_names_backend"] as? String != nil)
    }
}

@Suite("Analytics v2 catalogue")
struct AnalyticsV2CatalogueTests {
    @Test("STT model names are useful without allowing arbitrary text onto the wire")
    func transcriptionModelsAreNormalised() {
        let cases: [(String, String, String)] = [
            ("parakeet", "parakeet-tdt-0.6b-v3-coreml (ru+en)", "parakeet-v3"),
            ("parakeet", "parakeet-tdt-0.6b-v2-coreml", "parakeet-v2"),
            ("openai", "gpt-4o-transcribe-diarize", "gpt-4o-transcribe-diarize"),
            ("openai", "ft:private:customer-name", "custom"),
            ("assemblyai", "universal · auto-detect", "universal"),
            ("assemblyai", "private-model · ru+en", "custom"),
            ("other", "anything", "unknown"),
        ]
        for (engine, provenance, expected) in cases {
            #expect(
                AnalyticsCatalogue.transcriptionModel(engine: engine, provenance: provenance)
                    == expected,
                "\(engine): \(provenance)")
        }
    }

    @Test("LLM model names are allow-listed per backend")
    func summaryModelsAreNormalised() {
        let cases: [(String, String?, String)] = [
            ("claude-cli", nil, "default"),
            ("anthropic-api", "claude-opus-5", "claude-opus-5"),
            ("anthropic-api", "private/model", "custom"),
            ("codex-cli", "gpt-5", "gpt-5"),
            ("openai-api", "gpt-5", "gpt-5"),
            ("openai-api", "ft:customer:name", "custom"),
            ("ollama", "qwen3:8b", "qwen3:8b"),
            ("ollama", "samat/private-model", "custom-local"),
            ("other", "whatever", "unknown"),
        ]
        for (backend, model, expected) in cases {
            #expect(AnalyticsCatalogue.summaryModel(backend: backend, model: model) == expected)
        }
    }

    @Test("Recording start failures expose only the failed capture component")
    func recordingStartFailureComponents() {
        let underlying = NSError(domain: "private error text", code: 7)
        let system = RecordingSession.StartFailure.systemAudio(underlying)
        let microphone = RecordingSession.StartFailure.microphone(underlying)
        #expect(system.analyticsComponent == "system_audio")
        #expect(microphone.analyticsComponent == "microphone")
        #expect(system.description.contains("private error text"), "the local log keeps detail")
    }

    @Test("Errors collapse to a closed reason without carrying their text")
    func failureReasonsAreSafe() {
        #expect(Analytics.reason(for: URLError(.notConnectedToInternet)) == .noNetwork)
        #expect(Analytics.reason(for: URLError(.timedOut)) == .timedOut)
        #expect(Analytics.reason(for: LLMError.http(429, "private quota detail")) == .usageLimit)
        #expect(Analytics.reason(for: LLMError.http(503, "private server detail")) == .httpError)
        #expect(Analytics.reason(for: LLMError.http(401, "private key detail")) == .refused)
        #expect(Analytics.reason(for: LLMError.emptyResponse("private backend")) == .unknown)
    }
}

/// Which settings may be reported at all. The rule is toggles and fixed
/// choices; everything here is a way of asking whether the rule holds rather
/// than whether somebody remembered to apply it.
@Suite("Reportable settings")
struct AnalyticsCatalogueSettingsTests {
    @Test("Every toggle and choice is reportable, and nothing else is")
    func onlyTogglesAndChoices() {
        let reportable = AnalyticsCatalogue.reportableSettings
        for entry in SettingsSchema.sections.flatMap(\.entries) {
            let key = entry.path.joined(separator: ".")
            if AnalyticsCatalogue.neverReported.contains(key) {
                #expect(reportable[key] == nil, "\(key) is on the never-reported list")
                continue
            }
            switch entry.kind {
            case .toggle, .choice:
                #expect(reportable[key] != nil, "\(key) is a toggle or a choice but not reportable")
            case .text, .multilineText, .number, .list:
                #expect(reportable[key] == nil, "\(key) is free-form and must not be reportable")
            }
        }
    }

    /// The failure this guards against is the expensive one: a path, a name or
    /// a key file leaving the machine inside a `setting_changed`.
    @Test("Free-text settings produce no event whatever they are given")
    func freeTextNeverTravels() {
        let freeForm: [([String], Any)] = [
            (["recordings_dir"], "/Users/someone/Meetings with the board"),
            (["user_name"], "Someone Real"),
            (["on_stop"], "/usr/local/bin/leak.sh"),
            (["transcription", "assemblyai", "api_key_path"], "~/.config/amanu/keys/assemblyai"),
            (["summary", "api_key_path"], "~/.config/amanu/keys/anthropic"),
            (["transcription", "language"], "lv"),
            (["auto_record", "apps"], ["us.zoom.xos"]),
            (["auto_record", "start_delay_seconds"], 12),
        ]
        for (path, value) in freeForm {
            #expect(
                Analytics.reportableChange(path: path, value: value) == nil,
                "\(path.joined(separator: ".")) must not be reportable")
        }
    }

    @Test("The analytics switch never reports itself")
    func theSwitchIsSilent() {
        #expect(Analytics.reportableChange(path: ["analytics"], value: false) == nil)
        #expect(Analytics.reportableChange(path: ["analytics"], value: nil) == nil)
    }

    @Test("A toggle and a choice report their value, and a cleared key reports the default")
    func togglesAndChoicesReport() throws {
        let toggled = try #require(
            Analytics.reportableChange(path: ["auto_record", "enabled"], value: false))
        #expect(toggled.key == "auto_record.enabled")
        #expect(toggled.value == .flag(false))

        let cleared = try #require(
            Analytics.reportableChange(path: ["auto_record", "enabled"], value: nil))
        #expect(cleared.value == .text("default"))

        // A value the schema does not offer is not reported at all, which
        // keeps a hand-edited config file from putting free text on the wire
        // through a key that happens to be a choice.
        #expect(
            Analytics.reportableChange(
                path: ["transcription", "cloud"], value: "/etc/passwd") == nil)
    }

    @Test("Durations are buckets, and the boundaries are where they say they are")
    func durationBuckets() {
        #expect(Analytics.durationBucket(seconds: 0) == .text("under_5m"))
        #expect(Analytics.durationBucket(seconds: 299) == .text("under_5m"))
        #expect(Analytics.durationBucket(seconds: 300) == .text("5_15m"))
        #expect(Analytics.durationBucket(seconds: 1799) == .text("15_30m"))
        #expect(Analytics.durationBucket(seconds: 3600) == .text("1_2h"))
        #expect(Analytics.durationBucket(seconds: 90_000) == .text("over_2h"))
    }
}
