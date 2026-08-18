import Foundation

/// Answers "is a call app holding the microphone right now?" — the signal that
/// starts and ends an automatic recording.
///
/// It asks Core Audio which *processes* are running input rather than whether
/// the device is busy. That distinction is the whole design: our own capture
/// holds the input device too, and a monitor that couldn't tell the difference
/// would see its own recording as evidence of an ongoing meeting and never
/// stop (mygranola did exactly that before the per-process check — three
/// back-to-back recordings, about fifteen hours overnight, until the hard
/// duration cap ended them).
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
        /// Bundle-id families of those processes — what the system-audio tap
        /// is pointed at, so the far-end track carries the call and not the
        /// music playing next to it.
        var families: [String]
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
        guard let processes = AudioProcesses.all() else {
            // No per-process view: we cannot separate our own capture from
            // anyone else's, and a monitor that mistakes itself for a meeting
            // is worse than no monitor. Auto-record simply stays off.
            return Result(active: false, names: [], families: [], allHolders: [])
        }

        return evaluate(processes: processes, callApps: callApps, ignoring: ignoring)
    }

    /// The judgement itself, over a given list of processes — the same rule,
    /// without asking the system, so it can be tested.
    static func evaluate(
        processes: [AudioProcesses.Process],
        callApps: [String],
        ignoring: [String] = []
    ) -> Result {
        let holders = processes.filter(\.runningInput)
        var names: [String] = []
        var families: [String] = []
        for holder in holders {
            if alwaysIgnored.contains(holder.bundleID) { continue }
            if ignoring.contains(holder.bundleID) || ignoring.contains(holder.name) { continue }
            if !callApps.isEmpty && !AudioProcesses.belongs(holder, to: callApps) { continue }
            names.append(holder.name)
            if let family = AudioProcesses.family(of: holder, knownApps: callApps),
               !families.contains(family) {
                families.append(family)
            }
        }
        return Result(
            active: !names.isEmpty,
            names: names,
            families: families,
            allHolders: holders.map(\.name)
        )
    }
}
