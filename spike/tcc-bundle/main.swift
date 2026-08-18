// A minimal app bundle that answers one question: does a Developer ID-signed
// .app, launched by LaunchServices or by launchd as a login item, get real
// samples out of a Core Audio process tap — or the digitally silent, correctly
// clocked buffers that rca-002 measured for the bare binary run from a shell?
//
// It plays a tone through the default output device, taps all system audio for
// five seconds, and reports peak / RMS / share of non-zero samples, plus the
// launch context (parent and responsible process) that TCC attributes the tap
// to. Everything lands in ~/Library/Logs/amanu-spike/ and in an alert.
//
// Bundle id is me.samat.amanu.spike, deliberately not me.samat.amanu: this must
// not consume or disturb the grants the real program already holds.

import AVFoundation
import AppKit
import CoreAudio
import Darwin
import ServiceManagement

// MARK: - reporting

/// Writes every line to the log file and to stdout, and keeps the text around
/// for the alert — a Finder-launched app has no terminal to print to.
final class Report {
    let url: URL
    private let handle: FileHandle
    private(set) var text = ""

    init(directory: URL, stamp: String) throws {
        url = directory.appendingPathComponent("run-\(stamp).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func line(_ string: String = "") {
        print(string)
        text += string + "\n"
        try? handle.write(contentsOf: Data((string + "\n").utf8))
    }
}

// MARK: - launch context

/// The pid TCC will hold responsible for what this process does. Private SPI,
/// looked up rather than linked, because the whole point of the spike is to
/// see it: rca-002 showed a shell-launched binary is attributed to the
/// terminal, and an .app should be attributed to itself.
func responsiblePID() -> pid_t? {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    let value = unsafeBitCast(symbol, to: Fn.self)(getpid())
    return value < 0 ? nil : value
}

func path(ofPID pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return "(unknown)" }
    return String(cString: buffer)
}

func describeLaunch(into report: Report) {
    let bundle = Bundle.main
    report.line("bundle path      \(bundle.bundlePath)")
    report.line("bundle id        \(bundle.bundleIdentifier ?? "(none)")")
    report.line("running app id   \(NSRunningApplication.current.bundleIdentifier ?? "(none)")")
    report.line("pid              \(getpid()) — \(path(ofPID: getpid()))")

    let parent = getppid()
    report.line("parent pid       \(parent) — \(path(ofPID: parent))")

    if let responsible = responsiblePID() {
        let mine = responsible == getpid()
        report.line(
            "responsible pid  \(responsible) — \(path(ofPID: responsible))"
                + (mine ? "  [self: TCC judges this app on its own identity]" : "  [NOT self]")
        )
    } else {
        report.line("responsible pid  (SPI unavailable)")
    }

    let launched = parent == 1
        ? "launchd (login item, LaunchAgent, or a re-parented process)"
        : "another process — see the parent path above"
    report.line("launched by      \(launched)")
    report.line("login item       \(describe(SMAppService.mainApp.status))")
    report.line()
}

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: return "enabled"
    case .requiresApproval: return "requires approval in System Settings"
    case .notRegistered: return "not registered"
    case .notFound: return "not found"
    @unknown default: return "unknown"
    }
}

// MARK: - level statistics

/// Peak, RMS and the share of non-zero samples across everything the tap
/// delivered. Zero non-zero samples with a healthy packet count is the
/// signature rca-002 named: an unauthorized tap, not a broken audio graph.
final class TapStats {
    private let lock = NSLock()
    private var packets = 0
    private var samples = 0
    private var nonZero = 0
    private var peak: Float = 0
    private var sumOfSquares: Double = 0
    private var unreadableFormat = false

    func add(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0 else { return }

        var localNonZero = 0
        var localPeak: Float = 0
        var localSquares: Double = 0
        var readable = true

        if let data = buffer.floatChannelData {
            for channel in 0..<channels {
                let values = data[channel]
                for i in 0..<frames {
                    let value = values[i]
                    if value != 0 { localNonZero += 1 }
                    localPeak = max(localPeak, abs(value))
                    localSquares += Double(value) * Double(value)
                }
            }
        } else if let data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let values = data[channel]
                for i in 0..<frames {
                    let value = Float(values[i]) / Float(Int16.max)
                    if value != 0 { localNonZero += 1 }
                    localPeak = max(localPeak, abs(value))
                    localSquares += Double(value) * Double(value)
                }
            }
        } else {
            readable = false
        }

        lock.lock()
        packets += 1
        if readable {
            samples += frames * channels
            nonZero += localNonZero
            peak = max(peak, localPeak)
            sumOfSquares += localSquares
        } else {
            unreadableFormat = true
        }
        lock.unlock()
    }

    /// Verdict plus the numbers behind it.
    func summary() -> (verdict: String, lines: [String]) {
        lock.lock()
        let packets = packets, samples = samples, nonZero = nonZero
        let peak = peak, sumOfSquares = sumOfSquares, unreadable = unreadableFormat
        lock.unlock()

        func decibels(_ value: Double) -> String {
            value <= 0 ? "-inf dB" : String(format: "%.1f dB", 20 * log10(value))
        }
        let rms = samples > 0 ? (sumOfSquares / Double(samples)).squareRoot() : 0
        let share = samples > 0 ? 100 * Double(nonZero) / Double(samples) : 0

        var lines = [
            "packets          \(packets)",
            "samples          \(samples)",
            "non-zero         \(nonZero)  (\(String(format: "%.1f", share))%)",
            "peak             \(decibels(Double(peak)))",
            "rms              \(decibels(rms))",
        ]
        if unreadable { lines.append("note             a buffer arrived in an unmeasurable format") }

        let verdict: String
        if packets == 0 {
            verdict = "NO BUFFERS — the tap never fired, which is a different failure"
        } else if nonZero == 0 {
            verdict = "DIGITAL SILENCE — \(packets) well-formed packets, every sample zero"
        } else {
            verdict = "NON-ZERO SAMPLES — the tap is authorized and capturing"
        }
        return (verdict, lines)
    }
}

// MARK: - the tone

/// A 440 Hz sine through the default output device, so the spike does not
/// depend on the human remembering to start a video. The tap sees the mixed
/// output of every process, this one included.
func startTone() throws -> AVAudioEngine {
    let engine = AVAudioEngine()
    let mixer = engine.mainMixerNode
    let rate = mixer.outputFormat(forBus: 0).sampleRate
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
        throw NSError(domain: "spike", code: 1)
    }

    var phase: Float = 0
    let increment = 2 * Float.pi * 440 / Float(rate)
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let value = sin(phase) * 0.25
            phase += increment
            if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
            }
        }
        return noErr
    }
    engine.attach(source)
    engine.connect(source, to: mixer, format: format)
    try engine.start()
    return engine
}

// MARK: - the tap

enum SpikeError: Error, CustomStringConvertible {
    case tap(OSStatus), format(OSStatus), aggregate(OSStatus), ioProc(OSStatus), start(OSStatus)

    var description: String {
        switch self {
        case .tap(let s): return "AudioHardwareCreateProcessTap failed (OSStatus \(s))"
        case .format(let s): return "kAudioTapPropertyFormat unreadable (OSStatus \(s))"
        case .aggregate(let s): return "aggregate device creation failed (OSStatus \(s))"
        case .ioProc(let s): return "IO proc creation failed (OSStatus \(s))"
        case .start(let s): return "AudioDeviceStart failed (OSStatus \(s))"
        }
    }
}

/// Same shape as SystemAudioRecorder: a private global tap feeding a private
/// aggregate device, buffers arriving on an IO proc. Trimmed to what the
/// question needs — no scopes, no muting, no refresh.
func captureSystemAudio(seconds: TimeInterval, to url: URL, report: Report) throws -> TapStats {
    let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    description.name = "amanu spike tap"
    description.isPrivate = true
    description.muteBehavior = .unmuted

    var tapID = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
    guard tapStatus == noErr else { throw SpikeError.tap(tapStatus) }
    defer { AudioHardwareDestroyProcessTap(tapID) }
    report.line("tap created      id \(tapID)")

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let formatStatus = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
    guard formatStatus == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
        throw SpikeError.format(formatStatus)
    }
    report.line("tap format       \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")

    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "amanu-spike-tap",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]
        ],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    let aggregateStatus = AudioHardwareCreateAggregateDevice(
        aggregateDescription as CFDictionary, &aggregateID
    )
    guard aggregateStatus == noErr else { throw SpikeError.aggregate(aggregateStatus) }
    defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ],
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )

    let stats = TapStats()
    let queue = DispatchQueue(label: "me.samat.amanu.spike.tap")
    var procID: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
        _, inInputData, _, _, _ in
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil
        ) else { return }
        stats.add(buffer)
        try? file.write(from: buffer)
    }
    guard procStatus == noErr, let procID else { throw SpikeError.ioProc(procStatus) }
    defer { AudioDeviceDestroyIOProcID(aggregateID, procID) }

    let startStatus = AudioDeviceStart(aggregateID, procID)
    guard startStatus == noErr else { throw SpikeError.start(startStatus) }
    report.line("capturing        \(Int(seconds)) s → \(url.lastPathComponent)")

    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(aggregateID, procID)
    return stats
}

// MARK: - run

func runSpike() -> (title: String, body: String, logURL: URL?) {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/amanu-spike", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())

    guard let report = try? Report(directory: directory, stamp: stamp) else {
        return ("Spike failed", "Could not open a log file in \(directory.path).", nil)
    }

    report.line("amanu system-audio spike — \(Date())")
    report.line(String(repeating: "-", count: 60))
    describeLaunch(into: report)

    var engine: AVAudioEngine?
    do {
        engine = try startTone()
        report.line("tone             440 Hz playing through the default output device")
    } catch {
        report.line("tone             could not start (\(error)) — play audio by hand instead")
    }
    defer { engine?.stop() }

    do {
        let audioURL = directory.appendingPathComponent("run-\(stamp).caf")
        let stats = try captureSystemAudio(seconds: 5, to: audioURL, report: report)
        let (verdict, lines) = stats.summary()
        report.line()
        lines.forEach { report.line($0) }
        report.line()
        report.line("VERDICT          \(verdict)")
        report.line("log              \(report.url.path)")
        report.line("audio            \(audioURL.path)")
        return (verdict, report.text, report.url)
    } catch {
        report.line()
        report.line("VERDICT          FAILED — \(error)")
        return ("Spike failed", report.text, report.url)
    }
}

// MARK: - app

final class SpikeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSpike()
            DispatchQueue.main.async { self.present(result) }
        }
    }

    private func present(_ result: (title: String, body: String, logURL: URL?)) {
        let alert = NSAlert()
        alert.messageText = result.title
        alert.informativeText = result.body
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: SMAppService.mainApp.status == .enabled
            ? "Unregister login item" : "Register login item")
        alert.addButton(withTitle: "Reveal log")

        switch alert.runModal() {
        case .alertSecondButtonReturn: toggleLoginItem()
        case .alertThirdButtonReturn:
            if let url = result.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        default: break
        }
        NSApp.terminate(nil)
    }

    /// The second branch of the gate: SMAppService.mainApp, which makes launchd
    /// start this bundle at login. Registering is the only side effect the
    /// spike has outside its own log directory, and the same button undoes it.
    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        let alert = NSAlert()
        do {
            if service.status == .enabled {
                try service.unregister()
                alert.messageText = "Login item removed."
            } else {
                try service.register()
                alert.messageText = "Registered as a login item."
                alert.informativeText = "Log out and back in. The spike runs itself and writes "
                    + "another log to ~/Library/Logs/amanu-spike/. Status: "
                    + describe(service.status) + "."
            }
        } catch {
            alert.messageText = "Login item change failed."
            alert.informativeText = "\(error)"
        }
        alert.runModal()
    }
}

let delegate = SpikeDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
