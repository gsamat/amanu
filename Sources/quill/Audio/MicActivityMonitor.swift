import AppKit
import CoreAudio
import Foundation

/// Answers "is a call app holding the microphone right now?" — the signal that
/// starts and ends an automatic recording.
///
/// macOS 14.4 added per-process audio objects, so this asks Core Audio which
/// *processes* are running input rather than whether the device is busy. That
/// distinction is the whole design: our own capture holds the input device too,
/// and a monitor that couldn't tell the difference would see its own recording
/// as evidence of an ongoing meeting and never stop (mygranola did exactly
/// that before the per-process check — three back-to-back recordings, ~15 hours
/// overnight, until the hard duration cap ended them).
///
/// Attribution is deliberately by whitelist, not blacklist. "Some app opened
/// the mic" fires for dictation, Voice Memos, a browser tab checking levels —
/// and every false positive is a recording of something that isn't a meeting.
/// A missed meeting costs one click; a false one costs an unwanted recording of
/// whatever was in the room.
enum MicActivityMonitor {

    /// Never a meeting, whatever the config says. Dictation tools hold the mic
    /// for exactly as long as you speak, which is indistinguishable from a call
    /// by any timing rule.
    private static let alwaysIgnored: Set<String> = [
        "com.apple.VoiceMemos",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.speech.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.prakashjoshipax.VoiceInk",
    ]

    /// Bundle-id prefixes that mean "a call is happening". Prefixes rather than
    /// exact ids because the process that actually opens the mic is often a
    /// helper: Chrome's is `com.google.Chrome.helper`, Teams ships several.
    /// Browsers are in here because Meet and Zoom-in-a-tab are the common case;
    /// the cost is that a browser holding the mic for anything else looks like
    /// a meeting, which the minimum-duration rule then throws away.
    static let defaultCallApps: [String] = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.SkypeForBusiness",
        "com.skype.skype",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.google.Chrome.helper",
        "org.mozilla.firefox",
        "com.apple.Safari",
        "com.apple.WebKit.GPU",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
    ]

    struct Result {
        /// True when at least one process that counts as a call holds the mic.
        var active: Bool
        /// Human-readable names of those processes, for the menu and the log.
        var names: [String]
        /// Everything holding the mic, including what we filtered out. Useful
        /// when explaining "why isn't it recording" without a debugger.
        var allHolders: [String]
    }

    /// - Parameters:
    ///   - callApps: bundle-id prefixes that count as a meeting. Empty means
    ///     any process counts (minus the ignore lists) — the old, jumpier
    ///     behaviour, kept because it's the right answer for someone whose call
    ///     app isn't in any list.
    ///   - ignoring: extra bundle ids or process names to never count.
    static func check(callApps: [String], ignoring: [String] = []) -> Result {
        guard #available(macOS 14.4, *), let holders = micHolders() else {
            // No per-process view: we cannot separate our own capture from
            // anyone else's, and a monitor that mistakes itself for a meeting
            // is worse than no monitor. Auto-record simply stays off.
            return Result(active: false, names: [], allHolders: [])
        }

        var names: [String] = []
        for holder in holders {
            if alwaysIgnored.contains(holder.bundleId) { continue }
            if ignoring.contains(holder.bundleId) || ignoring.contains(holder.name) { continue }
            if !callApps.isEmpty && !callApps.contains(where: { holder.bundleId.hasPrefix($0) }) {
                continue
            }
            names.append(holder.name)
        }
        return Result(
            active: !names.isEmpty,
            names: names,
            allHolders: holders.map { $0.name }
        )
    }

    // MARK: -

    private struct Holder {
        let bundleId: String
        let name: String
    }

    @available(macOS 14.4, *)
    private static func micHolders() -> [Holder]? {
        guard let processes = audioProcessObjects() else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var holders: [Holder] = []
        for object in processes {
            guard let raw = uint32Property(object, kAudioProcessPropertyPID) else { continue }
            let pid = pid_t(bitPattern: raw)
            // Our own mic track is not evidence of anything.
            if pid == ownPID { continue }
            guard let running = uint32Property(object, kAudioProcessPropertyIsRunningInput),
                  running != 0 else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleId = stringProperty(object, kAudioProcessPropertyBundleID)
                ?? app?.bundleIdentifier
                ?? ""
            let name = app?.localizedName ?? bundleId
            holders.append(Holder(
                bundleId: bundleId,
                name: name.isEmpty ? "pid \(pid)" : name
            ))
        }
        return holders
    }

    /// The system's list of per-process audio objects. Selectors come from the
    /// SDK rather than four-char literals on purpose: a wrong one fails as
    /// "nobody is using the mic", which disables auto-record silently.
    @available(macOS 14.4, *)
    private static func audioProcessObjects() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, raw.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        return ids
    }

    private static func uint32Property(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // These properties follow Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does. Reading straight into a `var value: CFString`
        // both leaks it and hands Core Audio a pointer to a managed reference.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
