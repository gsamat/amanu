import AVFoundation
import Foundation

/// Peak level of a captured buffer, used for two things: knowing when a track
/// last carried actual speech (the silence backstop that ends a runaway
/// auto-recording) and muting a track while paused.
/// How the two tracks are written while recording.
///
/// Linear PCM, not AAC, and the reason is the whole point of the program.
/// AAC is variable-bitrate, so a CAF holding it is undecodable until its packet
/// table is written — at close. Kill the process mid-meeting and every byte on
/// disk is unreadable: `Missing packet table. It is required when block size or
/// frame size are variable.` Measured, not theorized (2026.08.17: 99 KB of AAC
/// on disk, zero seconds recoverable).
///
/// PCM has no packet table. Frames are fixed size, so whatever reached the disk
/// is decodable, and a stale chunk size in the header is arithmetic to repair.
/// The cost is about 1 GB per hour across both tracks, held only until the
/// transcript exists — TrackCompressor then turns each track into AAC and
/// deletes the PCM.
enum AudioFormats {
    /// 16-bit little-endian PCM at the device's own rate. 16 bits because the
    /// difference from 24 or float is inaudible under speech and halves the
    /// bytes at risk; the native rate because resampling in the capture
    /// callback is a second thing that can go wrong during a meeting.
    static func pcmSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

enum AudioLevel {
    /// Roughly −40 dBFS. Above the noise floor of a quiet room, below any
    /// speech worth transcribing — the same threshold mygranola settled on
    /// after measuring empty rooms.
    static let speechThreshold: Float = 0.01

    /// Absolute peak across all channels, or nil when the buffer's sample
    /// format isn't one we can read.
    ///
    /// nil is deliberately distinct from 0: callers use it to disable the
    /// silence backstop rather than to conclude "silent". A format we can't
    /// measure would otherwise look exactly like a dead-quiet meeting and stop
    /// the recording ten minutes in.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)

        if let data = buffer.floatChannelData {
            var peak: Float = 0
            for channel in 0..<channels {
                let samples = data[channel]
                for i in 0..<frames { peak = max(peak, abs(samples[i])) }
            }
            return peak
        }
        if let data = buffer.int16ChannelData {
            var peak: Int16 = 0
            for channel in 0..<channels {
                let samples = data[channel]
                for i in 0..<frames { peak = max(peak, abs(samples[i])) }
            }
            return Float(peak) / Float(Int16.max)
        }
        return nil
    }

    /// A zeroed buffer with the same format and length — what gets written
    /// while a session is paused, so the file keeps growing on the wall clock
    /// and every timestamp after the pause stays true.
    static func silence(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        silent.frameLength = buffer.frameLength

        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let data = silent.floatChannelData {
            for channel in 0..<channels { data[channel].update(repeating: 0, count: frames) }
        } else if let data = silent.int16ChannelData {
            for channel in 0..<channels { data[channel].update(repeating: 0, count: frames) }
        } else if let data = silent.int32ChannelData {
            for channel in 0..<channels { data[channel].update(repeating: 0, count: frames) }
        } else {
            // Unknown sample format: writing a buffer of uninitialized memory
            // would be worse than writing nothing at all.
            return nil
        }
        return silent
    }
}
