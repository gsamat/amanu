@preconcurrency import AVFoundation
import Foundation
import os.lock

/// A tiny boundary between Core Audio's borrowed callback memory and live ASR.
/// It does no asynchronous work itself: an installed sink receives an owned
/// copy and is responsible for enqueueing it without blocking.
final class LiveAudioBufferRelay: @unchecked Sendable {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    private struct State {
        var sink: Sink?
        var paused = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set { state.withLock { $0.paused = newValue } }
    }

    func install(_ sink: Sink?) {
        state.withLock { $0.sink = sink }
    }

    /// Returns false when forwarding is disabled or the buffer cannot be
    /// copied. Callers intentionally ignore that result: recording is the
    /// authoritative operation and live preview is best-effort.
    @discardableResult
    func forward(_ buffer: AVAudioPCMBuffer) -> Bool {
        let sink = state.withLock { state -> Sink? in
            state.paused ? nil : state.sink
        }
        guard let sink, let owned = Self.ownedCopy(of: buffer) else { return false }
        sink(owned)
        return true
    }

    private static func ownedCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard input.count == output.count else { return nil }

        for index in input.indices {
            let bytes = Int(input[index].mDataByteSize)
            guard let from = input[index].mData, let to = output[index].mData,
                  bytes <= Int(output[index].mDataByteSize)
            else { return nil }
            memcpy(to, from, bytes)
            output[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}
