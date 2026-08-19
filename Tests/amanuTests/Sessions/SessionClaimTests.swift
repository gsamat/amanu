import Foundation
import Testing

@testable import amanu

/// The file that says who is working on a session folder.
///
/// The case it exists for cannot be staged with one process, so a claim written
/// with this test runner's own pid stands in for a second amanu — the trick
/// `RecordingRecoveryTests` established for the recording manifest, and true in
/// the only way that matters: `kill(pid, 0)` says the owner is alive.
struct SessionClaimTests {
    private static func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["stop_reason": "manual"])
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    /// A claim as another process would have left it, written by hand so the
    /// pid in it can be one this test chooses.
    private static func plant(
        _ dir: URL, pid: Int32, stage: String = "transcribe"
    ) throws -> URL {
        let url = SessionClaim.url(dir)
        try JSONSerialization.data(
            withJSONObject: [
                "pid": pid,
                "started": "2026-08-20T09:00:00Z",
                "stage": stage,
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
        return url
    }

    /// A pid nothing is using. High enough to be past the wrap, and checked
    /// rather than assumed, because a false negative here would make the live
    /// case pass for the wrong reason.
    private static let deadPid: Int32 = 999_999

    @Test("A session a live process has claimed is not claimed again")
    func aLiveClaimIsNotGrantedTwice() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Our own pid stands in for a second amanu mid-transcription.
        let url = try Self.plant(dir, pid: ProcessInfo.processInfo.processIdentifier)
        let before = try Data(contentsOf: url)

        #expect(SessionClaim.isHeld(dir))
        do {
            try SessionClaim.acquire(dir, stage: .transcribe)
            Issue.record("Expected a live claim to refuse a second claimant.")
        } catch let busy as SessionClaim.Busy {
            // The two parts of one process that both reach for a folder — the
            // post-processing sweep and the transcription queue — are refused
            // in words that do not tell anyone to quit the app they are in.
            #expect(busy.description.contains("This copy of amanu"))
        }
        #expect(
            try Data(contentsOf: url) == before,
            "A refused claimant must not rewrite the owner's file."
        )
    }

    /// And the sentence the refusal carries, which is the whole of what `amanu
    /// process` prints when the app has the session. A real second process
    /// here, not our own pid: naming the pid is the point of the sentence, and
    /// a message about "another amanu" that turns out to mean this one is the
    /// mistake worth catching.
    @Test("Being refused says who has the session and what they are doing")
    func aBusyClaimSaysWhoAndWhat() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        _ = try Self.plant(dir, pid: other.processIdentifier, stage: "finish")

        do {
            try SessionClaim.acquire(dir, stage: .transcribe)
            Issue.record("Expected a live claim to refuse a second claimant.")
        } catch let busy as SessionClaim.Busy {
            #expect(busy.description.contains("pid \(other.processIdentifier)"))
            #expect(busy.description.contains("naming and summarizing"))
        }
    }

    @Test("A claim whose owner is gone is reclaimed, and the stale file replaced")
    func aDeadOwnersClaimIsReclaimed() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(kill(Self.deadPid, 0) != 0, "The stand-in for a dead owner must really be dead.")
        let url = try Self.plant(dir, pid: Self.deadPid)

        #expect(!SessionClaim.isHeld(dir))
        try SessionClaim.acquire(dir, stage: .transcribe)
        defer { SessionClaim.release(dir) }

        let holder = try #require(SessionClaim.holder(dir))
        #expect(holder.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(holder.stage == "transcribe")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The rule `recoverInterrupted` set for an unreadable manifest, kept here:
    /// not knowing who owns a folder is not a licence to take it.
    @Test("An unreadable claim is left alone and the session skipped")
    func anUnreadableClaimIsLeftAlone() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = SessionClaim.url(dir)
        try Data("half a fi".utf8).write(to: url)

        #expect(SessionClaim.isHeld(dir))
        #expect(SessionClaim.holder(dir) == nil)
        #expect(throws: SessionClaim.Busy.self) {
            try SessionClaim.acquire(dir, stage: .transcribe)
        }
        #expect(
            try String(contentsOf: url, encoding: .utf8) == "half a fi",
            "An unreadable claim must survive being met — deleting it is taking the folder."
        )
    }

    /// The half that rots: every claimant releases in a `defer`, so the claim
    /// outlives neither the work that succeeded nor the work that threw.
    @Test("A claim is released whether the work succeeds or throws")
    func aClaimIsReleasedOnBothPaths() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }

        struct Failed: Error {}
        func claimed(andThrow shouldThrow: Bool) throws {
            try SessionClaim.acquire(dir, stage: .finish)
            defer { SessionClaim.release(dir) }
            if shouldThrow { throw Failed() }
        }

        try claimed(andThrow: false)
        #expect(!FileManager.default.fileExists(atPath: SessionClaim.url(dir).path))

        #expect(throws: Failed.self) { try claimed(andThrow: true) }
        #expect(
            !FileManager.default.fileExists(atPath: SessionClaim.url(dir).path),
            "A claim left behind by a throw locks the session out until the process dies."
        )

        // And having been released twice, it is there to be taken again.
        try SessionClaim.acquire(dir, stage: .transcribe)
        SessionClaim.release(dir)
    }

    /// Releasing is the owner's own business. A process that was refused, or
    /// one whose claim was reclaimed after it was thought dead, must not delete
    /// the file that now belongs to somebody else.
    @Test("Releasing a claim somebody else holds does nothing")
    func releaseOnlyTouchesOurOwnClaim() throws {
        let dir = try Self.session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.plant(dir, pid: Self.deadPid)

        SessionClaim.release(dir)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
