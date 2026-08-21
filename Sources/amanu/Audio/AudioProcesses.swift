import AppKit
import CoreAudio
import Foundation

/// The system's per-process audio objects (macOS 14.4+), which are how amanu
/// answers both of its questions about other apps: who is holding the
/// microphone, and whose output should end up on the far-end track.
enum AudioProcesses {
    struct Process {
        /// The Core Audio object — what a tap description wants.
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        /// Display name, falling back to the executable's own name for
        /// processes AppKit knows nothing about. Never "pid 39277": these
        /// names reach folder names, where a number says nothing.
        let name: String
        let runningInput: Bool
        let runningOutput: Bool
    }

    /// Every audio process except our own — our capture must never be evidence
    /// about anyone else, and tapping ourselves would be a feedback loop.
    static func all() -> [Process]? {
        guard #available(macOS 14.4, *), let objects = processObjectList() else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return objects.compactMap { object -> Process? in
            guard let raw = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: raw)
            guard pid != ownPID else { return nil }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID)
                ?? app?.bundleIdentifier
                ?? ""
            let name = app?.localizedName
                ?? executableName(pid: pid)
                ?? bundleID.split(separator: ".").last.map(String.init)
                ?? ""
            return Process(
                object: object,
                pid: pid,
                bundleID: bundleID,
                name: name,
                runningInput: (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                runningOutput: (uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }

    /// Every process belonging to one of these families.
    ///
    /// A family is a bundle-id prefix — prefixes, not exact ids, because the
    /// process that plays a call's audio is rarely the one you'd name: Chrome
    /// renders it in `com.google.Chrome.helper.Renderer`, Teams and Zoom each
    /// ship several helpers, and matching the family catches all of them,
    /// including the ones not making any noise yet. A process with no bundle
    /// id at all (a command-line tool) is matched by its executable name
    /// instead, exactly.
    static func matching(families: [String]) -> [Process] {
        guard let processes = all() else { return [] }
        return matching(families: families, in: processes)
    }

    /// The selection itself, over a given list — the same rule, without asking
    /// the system, so it can be tested.
    static func matching(families: [String], in processes: [Process]) -> [Process] {
        guard !families.isEmpty else { return [] }
        return processes.filter { belongs($0, to: families) }
    }

    /// Whether a process belongs to one of these families: by bundle-id
    /// prefix, or — for something with no bundle id, like a command-line tool
    /// — by an exact match on its executable name.
    static func belongs(_ process: Process, to families: [String]) -> Bool {
        process.bundleID.isEmpty
            ? families.contains(process.name)
            : families.contains { !$0.isEmpty && process.bundleID.hasPrefix($0) }
    }

    /// The family a process belongs to: the app's own id rather than its
    /// helper's, so tapping "Chrome" doesn't mean tapping one renderer.
    ///
    /// Derived by matching against the configured call apps first — those are
    /// already written as family prefixes — then by dropping a trailing
    /// `.helper…` segment, and finally, for a process with no bundle id, by
    /// falling back to its executable name.
    static func family(of process: Process, knownApps: [String]) -> String? {
        guard !process.bundleID.isEmpty else {
            return process.name.isEmpty ? nil : process.name
        }
        if let known = knownApps.first(where: { !$0.isEmpty && process.bundleID.hasPrefix($0) }) {
            return known
        }
        if let range = process.bundleID.range(of: ".helper", options: [.caseInsensitive]) {
            return String(process.bundleID[..<range.lowerBound])
        }
        return process.bundleID
    }

    /// The devices a process is running input on — which microphone the call
    /// app is actually listening to, asked of the system rather than inferred
    /// from whatever happens to be the default.
    ///
    /// A process doing duplex I/O lists its output device here too (amanu's
    /// own voice-processing capture reports the speakers alongside the
    /// microphone), so callers filter by `AudioDevices.hasInput`.
    static func inputDevices(of process: Process) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process.object, &address, 0, nil, &size) == noErr,
              size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process.object, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    // MARK: -

    @available(macOS 14.4, *)
    private static func processObjectList() -> [AudioObjectID]? {
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

    private static func uint32(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
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

    private static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // These properties follow Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func executableName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        // `proc_name` null-terminates, so stop at the terminator rather than
        // decoding all 256 bytes — the rest of the buffer is zeroes, and
        // handing them to String is what the deprecated `init(cString:)` did.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}

@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ size: UInt32) -> Int32
