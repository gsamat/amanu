import Foundation
import Testing

@testable import quill

/// Crash recovery: a session interrupted by a crash, a kill, or a flat battery
/// must come back through the normal transcription queue on the next launch.
/// The CAF files survive on their own — what was missing was anything that
/// pointed at them.
@MainActor
struct RecordingRecoveryTests {
    /// A recordings root containing one session folder with an in-progress
    /// manifest, and audio of `bytes` in each track.
    private func makeInterruptedSession(
        pid: Int32,
        bytes: Int = 4096,
        started: Date = Date().addingTimeInterval(-600),
        title: String? = nil,
        environment: (root: URL, session: URL)? = nil
    ) throws -> (root: URL, session: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("quill-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("2026.08.17-1200", isDirectory: true)
        try fm.createDirectory(at: session, withIntermediateDirectories: true)

        for name in ["mic.caf", "system.caf"] {
            try Data(repeating: 0x41, count: bytes)
                .write(to: session.appendingPathComponent(name))
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
        // is exactly the state a crashed quill leaves behind.
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
        // Our own PID stands in for a second quill mid-recording.
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
}
