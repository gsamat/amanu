import Foundation

enum Config { static let didChange = Notification.Name("audit-config-change") }
enum InterfaceLanguage { enum Language: String { case en }; static let current = Language.en }
enum AnalyticsIdentity {
    static func isEnabled() -> Bool { false }
    static func isFirstRun() -> Bool { false }
    static func identifier() -> String { "audit-only" }
    static func markVersionSeen(_ version: String) -> Bool { false }
}
enum AnalyticsCatalogue {
    static func appVersion() -> String? { nil }
    static func personProperties() -> [String: Any] { [:] }
}
enum Analytics {
    enum Surface: String { case app }
    enum Event: String { case installed, versionSeen, recordingStarted }
    enum Property: String { case surface, value }
    enum Value: Sendable { case number(Double); var json: Any { switch self { case .number(let n): return n } } }
}
final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set(_ next: Bool) { lock.withLock { value = next } }
}
@main struct Repro {
    static func waitForRelease(_ gate: DispatchSemaphore) { _ = gate.wait(timeout: .now() + 10) }
    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let toggle = Switch(false)
        let disabled = AnalyticsSink(store: root.appendingPathComponent("disabled-queue.json"), transport: { _ in false }, switchIsOn: { toggle.get() }, identity: { ("audit", false) }, appVersion: { nil }, markVersionSeen: { _ in false })
        disabled.start(surface: .app)
        _ = disabled.bufferedCount
        toggle.set(true)
        NotificationCenter.default.post(name: Config.didChange, object: nil)
        disabled.record(.recordingStarted, [:])
        print("enable-after-disabled-start: expected buffered=1; actual=\(disabled.bufferedCount)")

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let overflow = AnalyticsSink(store: root.appendingPathComponent("overflow-queue.json"), transport: { body in
            let batch = try! JSONSerialization.jsonObject(with: body) as! [[String: Any]]
            let values = batch.compactMap { ($0["payload"] as? [String: Any])?["data"] as? [String: Any] }.compactMap { $0["value"] as? Double }
            print("transport snapshot: events=\(values.count); contains new event 500=\(values.contains(500))")
            entered.signal()
            waitForRelease(release)
            completed.signal()
            return true
        }, switchIsOn: { true }, identity: { ("audit", false) }, appVersion: { nil }, markVersionSeen: { _ in false })
        overflow.start(surface: .app)
        for i in 0..<500 { overflow.record(.recordingStarted, [.value: .number(Double(i))]) }
        _ = overflow.bufferedCount
        overflow.flush(waitingUpTo: 0.01)
        guard entered.wait(timeout: .now() + 5) == .success else { fatalError("transport did not start") }
        overflow.record(.recordingStarted, [.value: .number(500)])
        print("buffer after new event during send: \(overflow.bufferedCount)")
        release.signal()
        _ = completed.wait(timeout: .now() + 5)
        // Flush waits for the in-flight request and its queue completion.
        overflow.flush(waitingUpTo: 1)
        print("after send success: expected buffered=1 or second delivery of 500; actual buffered=\(overflow.bufferedCount)")
    }
}
