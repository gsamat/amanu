import CoreAudio
import Foundation

/// The devices macOS is routing through, by name and by identity.
///
/// Asked at the moments where the answer is worth keeping — when capture
/// starts, and when the route changes under it — and, now that the mic track
/// follows a microphone rather than merely inheriting one, asked again
/// whenever something might have moved.
///
/// Read on demand rather than cached: every answer here is a fact about right
/// now, and a stale one is worse than the query it saved.
enum AudioDevices {
    static func defaultInput() -> AudioObjectID? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutput() -> AudioObjectID? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func defaultInputName() -> String? { name(of: defaultInput()) }

    static func defaultOutputName() -> String? { name(of: defaultOutput()) }

    static func name(of device: AudioObjectID?) -> String? {
        guard let device else { return nil }
        var address = propertyAddress(kAudioObjectPropertyName)
        // These properties follow Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let name = value.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }

    /// Whether the device can record at all. Worth asking, because a process
    /// doing duplex I/O — anything with voice processing on, amanu included —
    /// lists its *output* device among the devices it is running input on, and
    /// a speaker is not a microphone.
    static func hasInput(_ device: AudioObjectID) -> Bool {
        channels(of: device, scope: kAudioObjectPropertyScopeInput) > 0
    }

    // MARK: -

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = propertyAddress(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func channels(
        of device: AudioObjectID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0
        else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return Int(UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels })
    }
}
