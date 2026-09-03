import Foundation
import Testing

@testable import amanu

/// The queue, and the three rules it exists to keep: nothing is sent when the
/// switch is off, nothing is lost to a restart, and nothing grows without a
/// ceiling.
@Suite("Analytics queue")
struct AnalyticsQueueTests {
    private static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending.json")
    }

    /// A transport that keeps what it was given and answers as told.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        let succeeds: Bool

        init(succeeds: Bool) { self.succeeds = succeeds }

        private func keep(_ body: Data) {
            lock.lock()
            bodies.append(body)
            lock.unlock()
        }

        var transport: AnalyticsSink.Transport {
            { [self] body in
                keep(body)
                return succeeds
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
            transport: transport ?? { _ in true },
            clock: clock,
            switchIsOn: { on },
            identity: { (id: "test-identity", isFirstRun: firstRun) })
    }

    @Test("With the switch off nothing is buffered and nothing is sent")
    func offSendsNothing() {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(
            store: store, on: false, firstRun: true, transport: recorder.transport)

        sink.start(surface: .app)
        sink.record(.recordingStarted, [.trigger: .text("manual")])
        sink.flush(waitingUpTo: 0.5)

        #expect(sink.bufferedCount == 0)
        #expect(recorder.sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    /// The one event nobody can fire twice: it means "this machine had no
    /// identifier", and asking for the identifier is what ends that.
    @Test("installed fires on the first run and not on the second")
    func installedIsOnce() {
        let store = Self.scratch()
        let first = Self.sink(store: store, firstRun: true, transport: { _ in false })
        first.start(surface: .app)
        first.flush(waitingUpTo: 0.5)
        #expect(first.bufferedCount == 1)

        let second = Self.sink(store: store, firstRun: false, transport: { _ in false })
        second.start(surface: .app)
        second.flush(waitingUpTo: 0.5)
        // The one from the first run, still unsent, and nothing added.
        #expect(second.bufferedCount == 1)
    }

    @Test("What could not be sent is still there after a restart")
    func failedSendsSurviveARestart() {
        let store = Self.scratch()
        let failing = Self.sink(store: store, transport: { _ in false })
        failing.start(surface: .app)
        failing.record(.recordingFinished, [.durationBucket: .text("5_15m")])
        failing.record(.transcriptFinished, [.engine: .text("parakeet")])
        failing.flush(waitingUpTo: 0.5)
        #expect(failing.bufferedCount == 2)

        let next = Self.sink(store: store, transport: { _ in false })
        next.start(surface: .app)
        next.flush(waitingUpTo: 0.5)
        #expect(next.bufferedCount == 2)
    }

    @Test("A successful send clears the queue")
    func successClearsTheQueue() {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(store: store, transport: recorder.transport)
        sink.start(surface: .app)
        sink.record(.summaryFinished, [.backend: .text("ollama")])
        sink.flush(waitingUpTo: 2)

        #expect(sink.bufferedCount == 0)
        #expect(recorder.sent.count == 1)
    }

    /// A laptop that spent a month offline should not come back with a month
    /// of events, and should not eat disk while it is away.
    @Test("The queue stops at its ceiling, dropping the oldest")
    func theQueueHasACeiling() {
        let store = Self.scratch()
        let sink = Self.sink(store: store, transport: { _ in false })
        sink.start(surface: .app)
        for _ in 0..<(AnalyticsSink.capacity + 40) {
            sink.record(.recordingStarted, [.trigger: .text("manual")])
        }
        sink.flush(waitingUpTo: 0.5)
        #expect(sink.bufferedCount == AnalyticsSink.capacity)
    }

    @Test("Events older than a week are dropped rather than sent late")
    func staleEventsAreDropped() {
        let store = Self.scratch()
        let old = Date()
        let stale = Self.sink(store: store, transport: { _ in false }, clock: { old })
        stale.start(surface: .app)
        stale.record(.recordingStarted, [.trigger: .text("manual")])
        stale.flush(waitingUpTo: 0.5)
        #expect(stale.bufferedCount == 1)

        let later = old.addingTimeInterval(AnalyticsSink.maximumAge + 60)
        let fresh = Self.sink(store: store, transport: { _ in false }, clock: { later })
        fresh.start(surface: .app)
        fresh.flush(waitingUpTo: 0.5)
        #expect(fresh.bufferedCount == 0)
    }

    /// The Umami batch shape, checked here rather than discovered in
    /// production: a body the server silently drops looks exactly like nobody
    /// using amanu.
    @Test("The body is a batch Umami can ingest")
    func theBodyIsWellFormed() throws {
        let store = Self.scratch()
        let recorder = Recorder(succeeds: true)
        let sink = Self.sink(store: store, transport: recorder.transport)
        sink.start(surface: .cli)
        sink.record(.recordingFinished, [
            .trigger: .text("calendar"),
            .durationBucket: .text("30_60m"),
            .liveUsed: .flag(true),
        ])
        sink.flush(waitingUpTo: 2)

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
            case .text, .number, .list:
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

/// The white list.
///
/// `docs/analytics.md` opens by saying it is the complete list — not the main
/// ones, the complete list — and the README repeats the promise. Nothing in
/// the compiler makes that true, and a page like that decays the first time
/// somebody adds an event and forgets. This is what stops it.
@Suite("Everything sent is written down")
struct AnalyticsCatalogueTests {
    static var page: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // amanuTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repository root
            return try String(
                contentsOf: root.appendingPathComponent("docs/analytics.md"), encoding: .utf8)
        }
    }

    @Test("Every event amanu can send is named in docs/analytics.md")
    func everyEventIsDocumented() throws {
        let page = try Self.page
        let missing = Analytics.Event.allCases
            .map(\.rawValue)
            .filter { !page.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/analytics.md: \(missing.joined(separator: ", "))")
    }

    @Test("Every property amanu can attach is named in docs/analytics.md")
    func everyPropertyIsDocumented() throws {
        let page = try Self.page
        let missing = Analytics.Property.allCases
            .map(\.rawValue)
            .filter { !page.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/analytics.md: \(missing.joined(separator: ", "))")
    }

    @Test("Every person property is named in docs/analytics.md")
    func everyPersonPropertyIsDocumented() throws {
        let page = try Self.page
        let missing = AnalyticsCatalogue.PersonProperty.allCases
            .map(\.rawValue)
            .filter { !page.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/analytics.md: \(missing.joined(separator: ", "))")
    }

    /// Every value `reason` can take, because "a closed list" is the claim
    /// the page makes about it and an undocumented member breaks that claim
    /// as surely as an undocumented event would.
    @Test("Every reason is named in docs/analytics.md")
    func everyReasonIsDocumented() throws {
        let page = try Self.page
        let reasons: [Analytics.Reason] = [
            .noNetwork, .noKey, .noModel, .audioMissing, .audioTooShort,
            .refused, .timedOut, .httpError, .quit, .unknown,
        ]
        let missing = reasons.map(\.rawValue).filter { !page.contains("`\($0)`") }
        #expect(missing.isEmpty, "not in docs/analytics.md: \(missing.joined(separator: ", "))")
    }

    /// The other direction. A page naming an event the program cannot send is
    /// a page somebody wrote against an older build, and it makes the whole
    /// list untrustworthy rather than merely incomplete.
    @Test("The page names no event the program cannot send")
    func thePageInventsNothing() throws {
        let page = try Self.page
        let known = Set(Analytics.Event.allCases.map(\.rawValue))
        // The events table only. The fields table below it has the same shape
        // and holds property names, which are checked against a different
        // list — reading both as events was this test's first mistake.
        let events = page.components(separatedBy: "## The events")
        let table = try #require(events.count == 2 ? events[1] : nil)
            .components(separatedBy: "\n## ")[0]
        let rows = table.components(separatedBy: "\n").filter { $0.hasPrefix("| `") }
        var invented: [String] = []
        for row in rows {
            let name = row.dropFirst(3).prefix { $0 != "`" }
            guard !name.isEmpty else { continue }
            if !known.contains(String(name)) { invented.append(String(name)) }
        }
        #expect(invented.isEmpty, "docs/analytics.md names: \(invented.joined(separator: ", "))")
    }

    @Test("The switch, the identifier file and the way to be forgotten are all on the page")
    func thePromisesAreOnThePage() throws {
        let page = try Self.page
        #expect(page.contains("amanu analytics off"))
        #expect(page.contains("~/.config/amanu/analytics"))
        #expect(page.contains("specs/2026-08-22-analytics-design.md"))
    }
}
