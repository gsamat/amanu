import Foundation

/// The buffer and the sender.
///
/// Written by hand rather than hidden in an analytics SDK. Umami's batch API
/// is one JSON POST, so the complete reporting surface stays small enough to
/// read end to end and check against `docs/analytics.md`.
///
/// Three rules it does not break. Analytics never blocks a caller: `record`
/// hands work to a serial queue and returns. Analytics never fails loudly: a
/// send that does not work is written down and tried at the next launch, and
/// a store that cannot be written is dropped in silence. Analytics never
/// delays quitting by more than a moment — see `flush(waitingUpTo:)`.
final class AnalyticsSink: @unchecked Sendable {
    typealias Transport = @Sendable (Data) async -> Bool

    /// Where events go. Umami's website id is public: it selects the dataset
    /// but grants no read access.
    enum Endpoint {
        static let url = URL(string: "https://stats.amanu.me/api/batch")!
        static let websiteID = "8ece1241-c45f-4976-9b20-d7004b2359b8"
        static var isConfigured: Bool { !websiteID.hasPrefix("UMAMI_WEBSITE_ID_REPLACE") }
    }

    static let shared = AnalyticsSink()

    /// Beside the identifier, so that forgetting everything amanu knows about
    /// this machine stays one `rm ~/.config/amanu/analytics*.json`.
    static let defaultStore = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/amanu/analytics-pending.json")

    /// Past this the backlog is somebody who has been offline for a month,
    /// and the oldest of it has stopped being worth the disk.
    static let capacity = 500
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let flushInterval: TimeInterval = 30

    /// Who this machine is, and whether it has ever said so before. One
    /// answer rather than two calls, because asking for the identifier is
    /// what makes the file, and "is this the first run" is only true before
    /// that happens.
    typealias Identity = @Sendable () -> (id: String, isFirstRun: Bool)

    private let queue = DispatchQueue(label: "me.samat.amanu.analytics")
    private let store: URL
    private let transport: Transport
    private let clock: @Sendable () -> Date
    private let switchIsOn: @Sendable () -> Bool
    private let identity: Identity
    /// Whether there is anywhere to send to. False for a build whose project
    /// key is still the placeholder, so a development copy cannot quietly
    /// post at a host that does not exist yet — and true whenever a transport
    /// was handed in, because a caller that brought its own destination has
    /// said where things go.
    private let hasSomewhereToSend: Bool

    private var pending: [[String: Any]] = []
    private var enabled = false
    private var identifier = ""
    private var surface = Analytics.Surface.app
    private var started = false
    private var sending = false
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    init(
        store: URL = AnalyticsSink.defaultStore,
        transport: Transport? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        switchIsOn: @escaping @Sendable () -> Bool = { AnalyticsIdentity.isEnabled() },
        identity: @escaping Identity = {
            // Read before asking, in this order and not the other one.
            let first = AnalyticsIdentity.isFirstRun()
            return (AnalyticsIdentity.identifier(), first)
        }
    ) {
        self.store = store
        self.transport = transport ?? AnalyticsSink.post
        self.clock = clock
        self.switchIsOn = switchIsOn
        self.identity = identity
        self.hasSomewhereToSend = transport != nil || Endpoint.isConfigured
    }

    // MARK: - starting

    func start(surface: Analytics.Surface) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            self.surface = surface
            enabled = switchIsOn()
            guard enabled else { return }

            let who = identity()
            identifier = who.id
            loadPending()
            if who.isFirstRun { append(.installed, [:]) }
            startTimer()
            watchTheSwitch()
        }
        flushSoon()
    }

    /// A switch that only takes effect at the next launch is a switch people
    /// reasonably believe did nothing.
    private func watchTheSwitch() {
        observer = NotificationCenter.default.addObserver(
            forName: Config.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.reread() }
        }
    }

    private func reread() {
        let nowEnabled = switchIsOn()
        guard nowEnabled != enabled else { return }
        enabled = nowEnabled
        if enabled {
            identifier = identity().id
            startTimer()
        } else {
            // Turning it off discards what has not gone yet. Anything else
            // would mean a switch that keeps sending for a week.
            timer?.cancel()
            timer = nil
            pending = []
            try? FileManager.default.removeItem(at: store)
        }
    }

    // MARK: - recording

    func record(_ event: Analytics.Event, _ properties: [Analytics.Property: Analytics.Value]) {
        queue.async { [self] in
            guard enabled, started else { return }
            append(event, properties)
        }
    }

    private func append(
        _ event: Analytics.Event, _ properties: [Analytics.Property: Analytics.Value]
    ) {
        var data = AnalyticsCatalogue.personProperties()
        for (key, value) in properties { data[key.rawValue] = value.json }
        data[Analytics.Property.surface.rawValue] = surface.rawValue
        pending.append([
            "type": "event",
            "payload": [
                "hostname": "app.amanu.me",
                "url": "/",
                "title": "Amanu",
                "language": InterfaceLanguage.current.rawValue,
                "website": Endpoint.websiteID,
                "name": event.rawValue,
                "id": identifier,
                "timestamp": clock().timeIntervalSince1970,
                "data": data,
            ],
        ])
        trim()
        savePending()
    }

    private func trim() {
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
    }

    // MARK: - sending

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.send() }
        timer.resume()
        self.timer = timer
    }

    private func flushSoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.send() }
    }

    /// Send what is buffered and wait, but not for long.
    ///
    /// Quitting is an instruction, and analytics does not get a vote on it.
    /// Whatever has not gone when the wait runs out is already on disk and
    /// goes at the next launch — which is why the timeout can be this rude.
    func flush(waitingUpTo seconds: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            guard enabled, !pending.isEmpty else {
                done.signal()
                return
            }
            send(then: { done.signal() })
        }
        _ = done.wait(timeout: .now() + seconds)
    }

    private func send(then finished: (@Sendable () -> Void)? = nil) {
        guard enabled, !sending, !pending.isEmpty, hasSomewhereToSend else {
            finished?()
            return
        }
        pending = pending.filter { !isExpired($0) }
        savePending()
        let batch = pending
        guard !batch.isEmpty, let body = encode(batch) else {
            finished?()
            return
        }
        sending = true
        let count = batch.count
        Task { [self] in
            let ok = await transport(body)
            queue.async { [self] in
                sending = false
                if ok {
                    // Only what was sent: the queue may have grown while the
                    // request was in flight, and dropping those would lose
                    // exactly the events of a busy minute.
                    pending.removeFirst(min(count, pending.count))
                    savePending()
                }
                finished?()
            }
        }
    }

    private func encode(_ batch: [[String: Any]]) -> Data? {
        var wireBatch: [[String: Any]] = []
        wireBatch.reserveCapacity(batch.count * 2)
        for event in batch {
            if let payload = event["payload"] as? [String: Any] {
                var identity: [String: Any] = [:]
                for key in ["website", "hostname", "language", "id", "timestamp"] {
                    if let value = payload[key] { identity[key] = value }
                }
                wireBatch.append(["type": "identify", "payload": identity])
            }
            wireBatch.append(event)
        }
        return try? JSONSerialization.data(withJSONObject: wireBatch)
    }

    private static let post: Transport = { body in
        var request = URLRequest(url: Endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        // A 4xx is the server saying this batch will never be accepted, so
        // treat it as delivered rather than retrying it for a week.
        return (200..<500).contains(http.statusCode)
    }

    // MARK: - the disk

    private func loadPending() {
        guard let data = try? Data(contentsOf: store),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stored = json["pending"] as? [[String: Any]]
        else { return }
        pending = stored.filter { !isExpired($0) }
        trim()
    }

    private func savePending() {
        guard let data = try? JSONSerialization.data(withJSONObject: ["pending": pending]) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    private func isExpired(_ event: [String: Any]) -> Bool {
        guard let payload = event["payload"] as? [String: Any],
              let stamp = payload["timestamp"] as? Double
        else { return false }
        let date = Date(timeIntervalSince1970: stamp)
        return clock().timeIntervalSince(date) > Self.maximumAge
    }

    private static var userAgent: String {
        let version = AnalyticsCatalogue.appVersion() ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X \(os.majorVersion)_\(os.minorVersion)) "
            + "Amanu/\(version)"
    }

    // MARK: - for tests

    var bufferedCount: Int { queue.sync { pending.count } }
}
