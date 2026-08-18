import AVFoundation
import AppKit
import CoreAudio
import EventKit
import Foundation

/// Asking macOS for what amanu needs, from inside the app rather than from a
/// terminal.
///
/// Where the asking happens is not a detail. macOS attributes a grant to the
/// process that asked for it, so a wizard run from a shell teaches the system
/// that *Terminal* may record — and amanu, started by launchd, then records a
/// full-length silent file with nothing to show for it (.issues/rca-002).
/// Everything here is called from the setup window, in the daemon.
@MainActor
enum SetupPermissions {
    /// What we can say about one permission. `unknown` is not laziness: for
    /// system audio there is no API that reads the answer, and pretending
    /// otherwise would be the more comfortable lie.
    enum State: Equatable {
        case granted
        case denied
        case notAsked
        case unknown
    }

    // MARK: - microphone

    static func microphone() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Raises the system prompt when nothing has been decided yet, and returns
    /// the answer. On a decided permission it returns what was decided without
    /// prompting — macOS wouldn't prompt again anyway.
    static func requestMicrophone() async -> State {
        guard microphone() == .notAsked else { return microphone() }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphone()
    }

    // MARK: - calendar

    static func calendar() -> State {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static func requestCalendar() async -> State {
        guard calendar() == .notAsked else { return calendar() }
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        return calendar()
    }

    // MARK: - launch at login

    /// Whether the Start-at-login row still has work in it. The bare binary
    /// used to have to hand itself over to launchd before any grant was worth
    /// asking for; an application is already its own responsible process, so
    /// the only question left is the ordinary one macOS asks of every app.
    static func needsStartAtLogin(loginItem: LoginItem.State) -> Bool {
        switch loginItem {
        case .enabled: return false
        // A bare build can't register anything, and nagging about it in a
        // window someone opened from `swift run` helps nobody.
        case .unavailable: return false
        case .notRegistered, .needsApproval: return true
        }
    }

    static var needsStartAtLogin: Bool {
        needsStartAtLogin(loginItem: LoginItem.status())
    }

    // MARK: - system audio

    /// What a test of the system-audio path found.
    enum SystemAudioResult: Equatable {
        /// A tap was created and it captured the tone we played.
        case heard
        /// A tap was created and captured silence. The interesting failure:
        /// this is what a terminal-launched amanu records for a whole meeting,
        /// and it is indistinguishable from a quiet room until you play a
        /// sound on purpose — which is what this does.
        case silent
        /// The tap could not be created at all.
        case refused(String)
    }

    /// The setup action stays useful until a deliberate tone has actually
    /// made the round trip. A refused tap is retryable after the user changes
    /// System Settings, just like a tap that captured silence.
    static func needsSystemAudioTest(_ result: SystemAudioResult?) -> Bool {
        result != .heard
    }

    /// How long a heard tone is taken at its word before the window asks for
    /// another one. Long enough that a working Mac is never nagged, short
    /// enough that a grant revoked months ago doesn't go on being believed.
    static let systemAudioMemory: TimeInterval = 30 * 24 * 60 * 60

    /// What a remembered test is still worth. A grant that was verified this
    /// month is reported as granted; anything older is treated as unknown and
    /// tested again, because the only evidence this permission ever gives is
    /// a tone that made it back.
    static func rememberedSystemAudio(
        heardAt: Date?,
        now: Date = Date(),
        memory: TimeInterval = systemAudioMemory
    ) -> SystemAudioResult? {
        guard let heardAt, now.timeIntervalSince(heardAt) <= memory, heardAt <= now else {
            return nil
        }
        return .heard
    }

    /// Create a process tap, play a short tone through the default output, and
    /// report whether the tap heard it.
    ///
    /// This is the only honest check available. There is no API that reads the
    /// system-audio TCC state, and the failure that costs a meeting is not "the
    /// prompt was declined" — it's a tap that is created, runs, and records
    /// silence. Making a sound and listening for it is the difference between
    /// knowing and assuming.
    ///
    /// Creating the tap is also what raises the one-time system prompt, so the
    /// same button both asks and verifies.
    static func testSystemAudio() async -> SystemAudioResult {
        let recorder = SystemAudioRecorder()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-tap-test-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            // Everything, not the call apps: the thing making a noise in a
            // moment is amanu itself.
            try recorder.start(writingTo: scratch, scope: .everything)
        } catch {
            return .refused("\(error)")
        }

        await playTone()
        recorder.stop()

        return recorder.lastSoundAt == nil ? .silent : .heard
    }

    /// A short, quiet tone through the default output. Quiet because someone
    /// is sitting in front of the machine, short because the tap only needs
    /// one buffer above the noise floor to prove itself.
    private static func playTone(seconds: Double = 0.9, frequency: Double = 440) async {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let output = engine.outputNode.inputFormat(forBus: 0)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: output.sampleRate, channels: 2
        ) else { return }

        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        let fade = Double(frames) * 0.05
        for channel in 0..<Int(format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frames) {
                // Faded in and out: an abrupt start and stop is a click, and a
                // click is what people remember about a setup screen.
                let position = Double(frame)
                let envelope = min(1, min(position, Double(frames) - position) / fade)
                samples[frame] = Float(
                    0.15 * envelope * sin(2 * .pi * frequency * position / format.sampleRate)
                )
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        defer { engine.stop() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer, at: nil, options: []) {
                continuation.resume()
            }
            player.play()
        }
        // The tap's buffers arrive a little behind the audio that produced
        // them; stopping the recorder the instant playback ends can lose the
        // very thing we played.
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - System Settings

    /// Panes worth being able to send someone to. The identifiers are the ones
    /// System Settings answers to; a wrong one opens the top of the app, which
    /// is unhelpful but harmless.
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        /// "Screen & System Audio Recording" — the pane that contains
        /// "System Audio Recording Only".
        case systemAudio = "Privacy_ScreenCapture"
        case calendar = "Privacy_Calendars"
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
