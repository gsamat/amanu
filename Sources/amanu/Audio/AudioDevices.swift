import CoreAudio
import Foundation

/// The names of the devices macOS is routing through right now.
///
/// Asked at the two moments where the answer is worth keeping: when capture
/// starts, and when the route changes under it. A track that suddenly hears
/// the room is explained by "output moved to the speakers", and that sentence
/// needs the names — without them a restart in meta.json says only that
/// something happened.
///
/// Read on demand rather than through a property listener: nothing here reacts
/// to a change, it only describes one that has already happened, and
/// `AVAudioEngineConfigurationChange` is the notification that matters.
enum AudioDevices {
    static func defaultInputName() -> String? {
        name(of: defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    static func defaultOutputName() -> String? {
        name(of: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    // MARK: -

    private static func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private static func name(of device: AudioObjectID?) -> String? {
        guard let device else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The name comes back retained under Core Foundation's create rule,
        // which is what takeRetainedValue settles.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let name = value.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }
}
