import Foundation
import Testing

@testable import amanu

/// Stand-in recorders: no device, no permission, and every answer a test can
/// set. What they exercise is the session around them — what a failed start
/// leaves behind, what `stop` writes and in which order, and what the watchdog
/// calls a stall.
final class FakeMicRecorder: MicTrackRecorder {
    var startError: Error?
    /// Runs inside `start`, before it succeeds, for a test that needs the
    /// real way a recorder fails (an Objective-C exception behind `guarded`).
    var duringStart: (() throws -> Void)?
    var writesFile = true
    private(set) var started = false
    private(set) var stopped = false
    var firstBufferAt: Date?
    var lastSoundAt: Date?
    var levelMeasurable = true
    var isMuted = false
    var capture = MicRecorder.Capture(
        requestedVoiceProcessing: false, initialVoiceProcessing: false,
        finalVoiceProcessing: false, inputDevice: nil, outputDevice: nil,
        sampleRate: nil, channels: nil, sampleFormat: nil)
    var restarts: [MicRecorder.Restart] = []

    func start(writingTo url: URL, callApps: [String]) throws {
        if let startError { throw startError }
        try duringStart?()
        started = true
        if writesFile { try Data(repeating: 1, count: 64).write(to: url) }
    }
    func stop() { stopped = true }
    func follow(callApps families: [String]) {}
    func checkRoute() {}
    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {}
    func setLiveAudioPaused(_ paused: Bool) {}
}

final class FakeSystemRecorder: SystemTrackRecorder {
    var startError: Error?
    var writesFile = true
    private(set) var started = false
    private(set) var stopped = false
    var scope: SystemAudioRecorder.Scope = .everything
    var firstBufferAt: Date?
    var lastSoundAt: Date?
    var levelMeasurable = true
    var isMuted = false

    func start(writingTo url: URL, scope: SystemAudioRecorder.Scope) throws {
        if let startError { throw startError }
        started = true
        if writesFile { try Data(repeating: 1, count: 64).write(to: url) }
    }
    func stop() { stopped = true }
    func refresh(scope newScope: SystemAudioRecorder.Scope) {}
    func installLiveAudioSink(_ sink: LiveAudioBufferRelay.Sink?) {}
    func setLiveAudioPaused(_ paused: Bool) {}
}

struct RefusedToStart: Error {}
struct DiskFull: Error {}

@MainActor
struct RecordingSessionTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func meta(in dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func manifest(in dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(".recording.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - start

    @Test("A mic that refuses after the tap started stops the tap and leaves nothing behind")
    func micFailureAfterSystemStart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        mic.startError = RefusedToStart()
        let session = try RecordingSession(root: root, mic: mic, system: system)

        #expect {
            try session.start(systemAudioScope: "all")
        } throws: { error in
            guard case RecordingSession.StartFailure.microphone = error else { return false }
            return true
        }
        #expect(system.started && system.stopped, "Half a session must never run silently.")
        #expect(!exists(session.dir.appendingPathComponent(".recording.json")))
        #expect(!exists(session.dir),
                "A folder with no meta.json is invisible to every list and would never be tidied.")
    }

    @Test("An Objective-C exception inside the mic start ends as a clean start failure")
    func micExceptionAfterSystemStart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        // What AVFAudio does on a second installTap or a format mismatch.
        mic.duringStart = {
            try MicRecorder.guarded {
                NSException(name: .genericException, reason: "tap busy", userInfo: nil).raise()
            }
        }
        let session = try RecordingSession(root: root, mic: mic, system: system)

        #expect {
            try session.start(systemAudioScope: "all")
        } throws: { error in
            guard case RecordingSession.StartFailure.microphone = error else { return false }
            return true
        }
        #expect(system.started && system.stopped, "The tap that had started must be stopped.")
        #expect(!exists(session.dir), "Nothing is left behind for a session that never ran.")
    }

    @Test("A tap that refuses to start leaves no folder behind")
    func systemFailureLeavesNoFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        system.startError = RefusedToStart()
        let session = try RecordingSession(root: root, mic: mic, system: system)

        #expect(throws: RecordingSession.StartFailure.self) {
            try session.start(systemAudioScope: "all")
        }
        #expect(!mic.started)
        #expect(!exists(session.dir))
    }

    // MARK: - stop

    @Test("A clean stop writes meta.json and only then drops the manifest")
    func cleanStop() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(systemAudioScope: "all")
        #expect(exists(session.dir.appendingPathComponent(".recording.json")))

        #expect(session.stop(reason: "manual"))

        #expect(try meta(in: session.dir)["stop_reason"] as? String == "manual")
        #expect(!exists(session.dir.appendingPathComponent(".recording.json")))
    }

    /// A track that never delivered a buffer has no audio for an offset to
    /// move. Counting it from the session's creation used to shift the track
    /// that did record by however long its own start took.
    @Test("A track that never delivered a buffer does not shift the one that did")
    func offsetsIgnoreASilentStart() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(systemAudioScope: "all")
        system.firstBufferAt = session.startedAt.addingTimeInterval(0.3)

        session.stop(reason: "manual")

        let offsets = try #require(try meta(in: session.dir)["start_offset_ms"] as? [String: Int])
        #expect(offsets == ["mic": 0, "system": 0])
    }

    @Test("Offsets are measured from the earlier of two first buffers")
    func offsetsFromTheEarlierTrack() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RecordingSession.startOffsets(mic: t.addingTimeInterval(0.25), system: t)
                == ["mic": 250, "system": 0])
        #expect(RecordingSession.startOffsets(mic: nil, system: nil) == ["mic": 0, "system": 0])
    }

    /// Disk full at the moment of stopping. Deleting the manifest regardless
    /// left a folder with neither marker, which no list, queue or recovery
    /// would ever look at again — audio on disk, session gone.
    @Test("A stop that cannot write meta.json keeps the session recoverable")
    func metaFailureKeepsTheManifest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(
            root: root, mic: mic, system: system,
            writeFile: { data, url in
                if url.lastPathComponent == "meta.json" { throw DiskFull() }
                try RecordingSession.durableWrite(data, url)
            })
        try session.start(systemAudioScope: "all")

        #expect(!session.stop(reason: "call-ended"),
                "a folder without meta.json was reported finished, and would be queued")

        #expect(!exists(session.dir.appendingPathComponent("meta.json")))
        let kept = try manifest(in: session.dir)
        #expect(kept["pid"] == nil,
                "With our pid still in it, the stopped session would read as recording now.")
        #expect(RecordingSession.inProgress(root: root).isEmpty)

        // Once the disk has room again, recovery puts it back as the stop meant it.
        let recovered = RecordingSession.recoverInterrupted(root: root)
        #expect(recovered.map(\.lastPathComponent) == [session.dir.lastPathComponent])
        let meta = try meta(in: session.dir)
        #expect(meta["stop_reason"] as? String == "call-ended")
        #expect(meta["recovered"] as? Bool == true)
        #expect(!exists(session.dir.appendingPathComponent(".recording.json")))
    }

    // MARK: - watchdog

    /// The mic recorder deletes its file when it restarts raw at the start;
    /// if that restart fails there is no file at all, and the watchdog used to
    /// skip missing files — so the one banner that could have said so, didn't.
    @Test("A track with no file at all is reported as stalled")
    func missingTrackIsStalled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        mic.writesFile = false
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(systemAudioScope: "all")
        defer { session.stop() }

        session.checkTrackLiveness(now: session.startedAt.addingTimeInterval(15))
        #expect(session.stalledTracks.isEmpty, "Too early to call anything stalled.")

        try Data(repeating: 2, count: 128).write(to: session.dir.appendingPathComponent("system.caf"))
        session.checkTrackLiveness(now: session.startedAt.addingTimeInterval(50))
        #expect(session.stalledTracks == ["mic"])
    }

    @Test("A track whose file stops growing is reported as stalled, and one that grows is not")
    func frozenTrackIsStalled() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMicRecorder(), system = FakeSystemRecorder()
        let session = try RecordingSession(root: root, mic: mic, system: system)
        try session.start(systemAudioScope: "all")
        defer { session.stop() }

        let start = session.startedAt
        session.checkTrackLiveness(now: start.addingTimeInterval(15))
        try Data(repeating: 2, count: 128).write(to: session.dir.appendingPathComponent("mic.caf"))
        session.checkTrackLiveness(now: start.addingTimeInterval(30))
        try Data(repeating: 2, count: 256).write(to: session.dir.appendingPathComponent("mic.caf"))
        session.checkTrackLiveness(now: start.addingTimeInterval(65))

        #expect(session.stalledTracks == ["system"])
    }

    // MARK: - recovery

    /// `kill(pid, 0)` answers EPERM for a process that exists but is not ours
    /// to signal. launchd is one, for anyone who is not root.
    @Test("A manifest owned by a process we may not signal is still a live one")
    func epermMeansAlive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.28-1000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: dir.appendingPathComponent("mic.caf"))
        try JSONSerialization.data(withJSONObject: [
            "pid": 1, "files": ["mic": "mic.caf"], "trigger": "manual",
        ]).write(to: dir.appendingPathComponent(".recording.json"))

        #expect(RecordingSession.processIsAlive(1))
        #expect(RecordingSession.inProgress(root: root).first?.ownerIsAlive == true)
        #expect(RecordingSession.recoverInterrupted(root: root).isEmpty)
        #expect(!exists(dir.appendingPathComponent("meta.json")))
    }

    @Test("An abandoned session with no audio is removed rather than reported forever")
    func emptyAbandonedSessionIsRemoved() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.28-1000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("system.caf"))
        try JSONSerialization.data(withJSONObject: [
            "pid": 999_999, "files": ["mic": "mic.caf", "system": "system.caf"],
        ]).write(to: dir.appendingPathComponent(".recording.json"))

        #expect(RecordingSession.recoverInterrupted(root: root).isEmpty)
        #expect(!exists(dir))
        #expect(RecordingSession.inProgress(root: root).isEmpty)
    }

    @Test("Recovery keeps the manifest when meta.json cannot be written")
    func recoveryKeepsManifestOnWriteFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.09.28-1000")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: dir.appendingPathComponent("mic.caf"))
        try JSONSerialization.data(withJSONObject: [
            "pid": 999_999, "files": ["mic": "mic.caf"],
        ]).write(to: dir.appendingPathComponent(".recording.json"))

        let recovered = RecordingSession.recoverInterrupted(
            root: root, writeFile: { _, _ in throw DiskFull() })

        #expect(recovered.isEmpty)
        #expect(exists(dir.appendingPathComponent(".recording.json")),
                "Without either marker the folder is no longer a session to anything.")
    }
}
