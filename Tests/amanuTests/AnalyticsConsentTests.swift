import Foundation
import Testing

@testable import amanu

@Suite("Analytics consent and delivery transitions", .serialized)
struct AnalyticsConsentTests {
    @Test("Flushing before start never creates an identity or a queue")
    func flushBeforeStart() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = AnalyticsSink(store: root.appendingPathComponent("pending.json"),
                                 transport: { _ in true }, switchIsOn: { true },
                                 identity: { Issue.record("Identity requested before start"); return ("test", true) })
        sink.flush(waitingUpTo: 0.1)
        #expect(sink.bufferedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test("Temporary HTTP rejection keeps the batch retryable")
    func retryableResponses() {
        for status in [408, 429, 500, 503] {
            #expect(!AnalyticsSink.acceptsResponse(status: status))
        }
        for status in [200, 204, 400, 401, 413] {
            #expect(AnalyticsSink.acceptsResponse(status: status))
        }
    }

    @Test("An opted-out launch removes events left by an earlier process")
    func optedOutLaunchClearsDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("pending.json")
        try Data("previous backlog".utf8).write(to: store)
        let sink = sink(store, Switch(false))
        sink.start(surface: .app)
        #expect(sink.bufferedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        func get() -> Bool { lock.withLock { value } }
        func set(_ value: Bool) { lock.withLock { self.value = value } }
    }

    private actor Delivery {
        private var firstReply: CheckedContinuation<Bool, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private(set) var bodies: [Data] = []

        func send(_ body: Data) async -> Bool {
            bodies.append(body)
            guard bodies.count == 1 else { return true }
            return await withCheckedContinuation { reply in
                firstReply = reply
                started?.resume()
                started = nil
            }
        }

        func waitForFirstSend() async {
            if firstReply != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func deliverFirst() {
            firstReply?.resume(returning: true)
            firstReply = nil
        }
    }

    private actor Collector {
        private(set) var bodies: [Data] = []
        func send(_ body: Data) -> Bool { bodies.append(body); return true }
    }

    @Test("Free text cannot escape through engine, backend or recovery trigger properties")
    func arbitraryConfigurationStaysLocal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = Collector()
        let sink = sink(root.appendingPathComponent("pending.json"), Switch(true),
                        transport: { await collector.send($0) })
        sink.start(surface: .app)
        sink.record(.transcriptFailed, [.engine: .text("private-engine-name"),
                                      .backend: .text("private-server-name"),
                                      .trigger: .text("private-meeting-name")])
        await Task.detached { sink.flush(waitingUpTo: 2) }.value
        let bodies = await collector.bodies
        #expect(bodies.count == 1)
        let text = String(decoding: try #require(bodies.first), as: UTF8.self)
        #expect(!text.contains("private-"))
    }

    private func sink(_ store: URL, _ toggle: Switch,
                      transport: @escaping AnalyticsSink.Transport = { _ in false }) -> AnalyticsSink {
        AnalyticsSink(store: store, transport: transport, switchIsOn: { toggle.get() },
                      identity: { ("consent-test", false) }, appVersion: { nil },
                      markVersionSeen: { _ in false })
    }

    @Test("Enabling analytics after an opted-out launch starts collecting")
    func enableAfterOptedOutLaunch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let toggle = Switch(false)
        let sink = sink(root.appendingPathComponent("pending.json"), toggle)
        sink.start(surface: .app)
        #expect(sink.bufferedCount == 0)

        toggle.set(true)
        NotificationCenter.default.post(name: Config.didChange, object: nil)
        sink.record(.recordingStarted, [:])

        #expect(sink.bufferedCount == 1)
    }

    @Test("A config change outside this process is respected before collecting or sending")
    func externalOptOut() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let toggle = Switch(true)
        let sink = sink(root.appendingPathComponent("pending.json"), toggle)
        sink.start(surface: .app)
        sink.record(.recordingStarted, [:])
        #expect(sink.bufferedCount == 1)

        // Another process can update the file without posting our local notification.
        toggle.set(false)
        sink.record(.recordingFinished, [:])
        await Task.detached { sink.flush(waitingUpTo: 1) }.value

        #expect(sink.bufferedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("pending.json").path))
    }

    @Test("A full queue cannot acknowledge an event that arrived after the request started")
    func overflowDuringDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let delivery = Delivery()
        let sink = sink(root.appendingPathComponent("pending.json"), Switch(true),
                        transport: { await delivery.send($0) })
        sink.start(surface: .app)
        for _ in 0..<AnalyticsSink.capacity { sink.record(.recordingStarted, [:]) }
        #expect(sink.bufferedCount == AnalyticsSink.capacity)
        sink.flush(waitingUpTo: 0)
        await delivery.waitForFirstSend()
        sink.record(.summaryFinished, [:])
        #expect(sink.bufferedCount == AnalyticsSink.capacity)

        await delivery.deliverFirst()
        await Task.detached { sink.flush(waitingUpTo: 2) }.value

        let bodies = await delivery.bodies
        let names = try bodies.flatMap { body -> [String] in
            let batch = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
            return batch.compactMap { ($0["payload"] as? [String: Any])?["name"] as? String }
        }
        #expect(names.filter { $0 == "summary_finished" }.count == 1)
    }
}
