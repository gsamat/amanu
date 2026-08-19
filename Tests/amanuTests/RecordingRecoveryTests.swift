import Foundation
import Testing

@testable import amanu

/// The in-progress manifest, from both ends: crash recovery adopts a session
/// interrupted by a crash, a kill or a flat battery so it comes back through
/// the normal transcription queue on the next launch — the CAF files survive on
/// their own, what was missing was anything that pointed at them — and the same
/// file is the only thing on disk that can say a recording is happening now.
@MainActor
struct RecordingRecoveryTests {
    /// A recordings root containing one session folder with an in-progress
    /// manifest, and audio of `bytes` in each track. Pass `into` to put a
    /// second session beside an existing one in the same root.
    private func makeInterruptedSession(
        pid: Int32,
        bytes: Int = 4096,
        started: Date = Date().addingTimeInterval(-600),
        title: String? = nil,
        name: String = "2026.08.17-1200",
        into existingRoot: URL? = nil
    ) throws -> (root: URL, session: URL) {
        let fm = FileManager.default
        let root = existingRoot ?? fm.temporaryDirectory
            .appendingPathComponent("amanu-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)

        for track in ["mic.caf", "system.caf"] {
            try Data(repeating: 0x41, count: bytes)
                .write(to: session.appendingPathComponent(track))
        }

        var manifest: [String: Any] = [
            "pid": pid,
            "started": ISO8601DateFormatter().string(from: started),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "trigger": "mic-activity",
            "start_offset_ms": ["mic": 0, "system": 120],
        ]
        if let title { manifest["title"] = title }
        try JSONSerialization
            .data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: session.appendingPathComponent(".recording.json"))

        return (root, session)
    }

    private func meta(in session: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: session.appendingPathComponent("meta.json"))
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @Test("An interrupted session is adopted and queued like a clean one")
    func interruptedSessionIsRecovered() throws {
        // A PID above the system's maximum: nothing can be running there, which
        // is exactly the state a crashed amanu leaves behind.
        let (root, session) = try makeInterruptedSession(pid: 999_999, title: "Sync")
        defer { try? FileManager.default.removeItem(at: root) }

        let recovered = RecordingSession.recoverInterrupted(root: root)

        // Compared by name: the temporary directory reaches us as /var/… and
        // comes back as /private/var/…, the same place by two paths.
        #expect(recovered.map { $0.lastPathComponent } == [session.lastPathComponent])
        let meta = try meta(in: session)
        #expect(meta["stop_reason"] as? String == "recovered-after-crash")
        #expect(meta["recovered"] as? Bool == true)
        #expect(meta["title"] as? String == "Sync")
        #expect(meta["trigger"] as? String == "mic-activity")
        // The queue reads these two; without them the session is unusable even
        // though it was "recovered".
        #expect((meta["files"] as? [String: String])?["mic"] == "mic.caf")
        #expect((meta["start_offset_ms"] as? [String: Int])?["system"] == 120)
        #expect(
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent(".recording.json").path
            ) == false,
            "The manifest must be gone, or the next launch recovers it again."
        )
    }

    @Test("A session owned by a live process is left strictly alone")
    func liveSessionIsNotTouched() throws {
        // Our own PID stands in for a second amanu mid-recording.
        let own = ProcessInfo.processInfo.processIdentifier
        let (root, session) = try makeInterruptedSession(pid: own)
        defer { try? FileManager.default.removeItem(at: root) }

        let recovered = RecordingSession.recoverInterrupted(root: root)

        #expect(recovered.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: session.appendingPathComponent("meta.json").path
            ) == false,
            "Writing meta.json under a live recorder would queue a session that is still being written."
        )
        #expect(FileManager.default.fileExists(
            atPath: session.appendingPathComponent(".recording.json").path
        ))
    }

    @Test("A session with no audio is skipped rather than queued empty")
    func emptyTracksAreSkipped() throws {
        let (root, session) = try makeInterruptedSession(pid: 999_999, bytes: 0)
        defer { try? FileManager.default.removeItem(at: root) }

        let recovered = RecordingSession.recoverInterrupted(root: root)

        #expect(recovered.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: session.appendingPathComponent("meta.json").path
        ) == false)
    }

    @Test("A stale manifest next to a finished session is just cleaned up")
    func staleManifestIsRemoved() throws {
        let (root, session) = try makeInterruptedSession(pid: 999_999)
        defer { try? FileManager.default.removeItem(at: root) }

        // A clean stop that wrote meta.json but failed to delete the manifest.
        try JSONSerialization.data(withJSONObject: ["stop_reason": "manual"])
            .write(to: session.appendingPathComponent("meta.json"))

        let recovered = RecordingSession.recoverInterrupted(root: root)

        #expect(recovered.isEmpty)
        let meta = try meta(in: session)
        #expect(
            meta["stop_reason"] as? String == "manual",
            "Recovery must never overwrite the meta.json of a session that ended cleanly."
        )
        #expect(FileManager.default.fileExists(
            atPath: session.appendingPathComponent(".recording.json").path
        ) == false)
    }

    // MARK: - what is being recorded right now

    @Test("A recording in progress is reported with its pid and start time")
    func liveRecordingIsReported() throws {
        // Our own PID stands in for the amanu that is recording; nothing else
        // on the machine can be relied upon to be alive for the length of a
        // test.
        let own = ProcessInfo.processInfo.processIdentifier
        let started = Date().addingTimeInterval(-252)
        let (root, session) = try makeInterruptedSession(pid: own, started: started)
        defer { try? FileManager.default.removeItem(at: root) }

        let underway = RecordingSession.inProgress(root: root)

        #expect(underway.count == 1)
        #expect(underway.first?.dir.lastPathComponent == session.lastPathComponent)
        #expect(underway.first?.pid == own)
        #expect(underway.first?.ownerIsAlive == true)
        let reported = try #require(underway.first?.started)
        #expect(abs(reported.timeIntervalSince(started)) < 1)
    }

    @Test("A manifest whose owner is gone is reported as stale, not as live")
    func deadOwnerIsNotALiveRecording() throws {
        let (root, _) = try makeInterruptedSession(pid: 999_999)
        defer { try? FileManager.default.removeItem(at: root) }

        let underway = RecordingSession.inProgress(root: root)

        // Still reported — the folder is a crashed session waiting for the
        // next launch, and saying nothing about it would be the same silence
        // that made this worth checking. Just not as something being recorded.
        #expect(underway.count == 1)
        #expect(underway.first?.ownerIsAlive == false)
    }

    @Test("A finished session that kept its manifest is not a recording")
    func manifestBesideMetaIsNotARecording() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let (root, session) = try makeInterruptedSession(pid: own)
        defer { try? FileManager.default.removeItem(at: root) }

        // A clean stop that wrote meta.json but failed to delete the manifest.
        // Warning about this would be a warning that never goes away, since
        // the pid it names is this very process.
        try JSONSerialization.data(withJSONObject: ["stop_reason": "manual"])
            .write(to: session.appendingPathComponent("meta.json"))

        #expect(RecordingSession.inProgress(root: root).isEmpty)
    }

    @Test("A manifest that cannot be read is skipped rather than thrown")
    func malformedManifestIsSkipped() throws {
        let (root, session) = try makeInterruptedSession(pid: 999_999)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{ not json".utf8)
            .write(to: session.appendingPathComponent(".recording.json"))

        // Doctor asks this question on every startup; a truncated write must
        // cost a line of output, not the launch.
        #expect(RecordingSession.inProgress(root: root).isEmpty)
    }

    @Test("Every live recording in the root comes back, not just the first")
    func severalLiveRecordingsAreAllReported() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let (root, _) = try makeInterruptedSession(pid: own, name: "2026.08.17-1200")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeInterruptedSession(pid: own, name: "2026.08.17-1400", into: root)

        let underway = RecordingSession.inProgress(root: root)

        #expect(underway.map { $0.dir.lastPathComponent }
            == ["2026.08.17-1200", "2026.08.17-1400"])
        #expect(underway.allSatisfy { $0.ownerIsAlive })
    }
}
