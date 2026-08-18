---
title: "Voice processing produces a silent mic track"
date: 2026-07-25
status: done
affects: "microphone recording and speaker attribution"
---

## Context

Quill records the default microphone through an `AVAudioEngine` input-node tap and records system playback through a separate Core Audio process tap. Commit `374e479` enabled `setVoiceProcessingEnabled(true)` on the input node to prevent speaker playback from appearing in both transcripts. Commit `0d294bc` added a 9-channel-to-mono `AVAudioConverter` after direct AAC writes from the 9-channel tap failed.

Apple's voice-processing mode is not an input effect. It replaces the engine's normal I/O with a duplex voice-processing I/O configuration. Enabling it on either I/O node automatically enables it on the other. The input node's output format and output node's input format must match, and the engine must render to an audio device [1](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled%28_%3A%29). The underlying `VoiceProcessingIO` unit uses bus 0 for device output and bus 1 for processed device input [2](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_voiceprocessingio).

Apple's official `UsingVoiceProcessing` sample supplies the missing graph configuration [3](https://developer.apple.com/documentation/avfaudio/using-voice-processing). It chooses an explicit mono client format, connects `mainMixerNode` to `outputNode` with that format, and installs the input tap with the same format. It does not read the input node's post-enable default format and downmix it after capture.

## Problem statement

With voice processing disabled, the current mic path records at approximately -27.6 dB and transcribes correctly. With voice processing enabled:

1. The input node reports 9 channels at 48 kHz.
2. Writing those buffers directly to an AAC-in-CAF file fails on every write and leaves a 4 KB, zero-frame file.
3. Converting the buffers to mono before AAC encoding creates a correctly timed file, but its decoded signal remains at approximately -91 dB mean and maximum.
4. Two consecutive sessions reproduce the digital silence.

The system-audio track remains independent and usable.

## RCA

The root cause is incomplete VoiceProcessingIO graph and format configuration. Quill enables the duplex unit, immediately accepts `input.outputFormat(forBus: 0)` as its client format, and never establishes the output side of the graph. On the affected route, the inherited format is 9-channel/48 kHz. The subsequent `AVAudioConverter` is downstream of VoiceProcessingIO and cannot repair the unit's I/O configuration.

The working Apple graph does four things in order:

1. Enable voice processing while the engine is stopped.
2. Choose an explicit mono Voice I/O client format.
3. Connect `mainMixerNode` to `outputNode` with that format.
4. Install the input tap with that same format.

Calling `setVoiceProcessingEnabled(true)` on `outputNode` remains unnecessary because enabling either I/O node enables both. Constructing and formatting the output render path is necessary.

The 9-channel format is not the desired post-AEC speech format. It is the unconfigured client format inherited from the multichannel hardware or synthesized aggregate route. VoiceProcessingIO supports conversion between its hardware and client scopes, so Quill should request mono at the Voice I/O boundary instead of accepting nine channels and converting later. Apple's underlying unit defines a macOS error for unexpected hardware input channel counts [4](https://developer.apple.com/documentation/audiotoolbox/kauvoiceioerr_unexpectednumberofinputchannels), so a genuinely incompatible device may still fail and needs a raw-mic fallback.

The direct AAC failure is separate. Writing the inherited 9-channel buffers to the current AAC file fails. The mono converter fixes the file shape but leaves the VoiceProcessingIO misconfiguration in place, which explains why it creates a correctly timed silent file rather than restoring the microphone.

The remaining uncertainty is route support, not the intended graph. The corrected mono duplex graph must be tested on the current 9-channel default device. If its tap still returns zeros, the hardware route is incompatible or affected by a macOS 26 `AUVPAggregate` defect. Recent reports show the same internal path failing with mismatched default input and output devices [5](https://developer.apple.com/forums/thread/810129).

## Proposed fix

Implement the Apple sample's graph shape in `MicRecorder`. Use one explicit mono format on both sides of VoiceProcessingIO and write the tapped mono PCM directly to the AAC file:

```swift
let input = engine.inputNode
try input.setVoiceProcessingEnabled(true)

guard let voiceFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48_000,
    channels: 1,
    interleaved: false
) else {
    throw RecorderError.formatUnsupported(input.outputFormat(forBus: 0))
}

let output = engine.outputNode
let mixer = engine.mainMixerNode
engine.connect(mixer, to: output, format: voiceFormat)

input.installTap(onBus: 0, bufferSize: 1024, format: voiceFormat) {
    [weak self] buffer, _ in
    guard let self, let file = self.file else { return }
    if self.firstBufferAt == nil { self.firstBufferAt = Date() }
    do {
        try file.write(from: buffer)
    } catch {
        FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
    }
}
```

The mixer has no sources, so Quill does not monitor the microphone or add playback. Its connection exists to make VoiceProcessingIO a complete, rendered duplex graph.

Instrument the first corrected recording:

1. Log `inputNode.inputFormat`, `inputNode.outputFormat`, `outputNode.inputFormat`, and `outputNode.outputFormat` after the graph is connected.
2. Confirm `inputNode.isVoiceProcessingEnabled` and `outputNode.isVoiceProcessingEnabled`.
3. Calculate peak and RMS on the mono tap before encoding.
4. Run once with the current 9-channel default input and once with the built-in microphone and built-in speakers selected as the default pair.

The result has a predetermined branch:

- The mono tap has signal and speaker echo is removed: keep voice processing and remove the downstream converter.
- The built-in pair works and the 9-channel route fails: gate voice processing to compatible default-device pairs and fall back to raw capture elsewhere.
- Both routes remain silent: reduce to the Apple sample graph as a macOS reproduction and treat the failure as a framework or daemon-context issue.

Add a first-second liveness check before trusting the session. If callbacks arrive but their peak remains at digital zero, stop and recreate the engine with voice processing disabled. This protects recordings from silent framework failures without abandoning AEC on supported routes.

Transcript-level echo suppression remains a fallback for unsupported devices, not the primary fix. Quill already has the clean far-end track and aligned timestamps. Mark a mic segment as echo only when it overlaps a system segment in time and has high fuzzy token similarity; preserve segments with substantial unique mic words so local interruptions and double-talk survive.

Direct `kAudioUnitSubType_VoiceProcessingIO` is unnecessary unless AVAudioEngine still fails after matching Apple's graph. It exposes the same unit with lower-level control.

`AVCaptureSession` with `.voiceIsolation` is not a programmatic substitute. Microphone Modes require adoption of `AUVoiceIO`, and the user, not the app, selects Voice Isolation in Control Center [6](https://developer.apple.com/videos/play/wwdc2021/10047/?time=1388). `preferredMicrophoneMode` and `activeMicrophoneMode` are read-only observations [7](https://developer.apple.com/documentation/avfoundation/avcapturedevice/preferredmicrophonemode).

## Relevant files

**Fix targets:**

- `Sources/amanu/Audio/MicRecorder.swift` — enables duplex voice processing, reads the 9-channel format, converts it to mono, and writes the mic track.
- `Sources/amanu/Config.swift` — currently makes voice processing default-on.
- `README.md` — currently promises echo cancellation as the default behavior.
- `Sources/amanu/Transcription/TranscriptionCoordinator.swift` — appropriate location for cross-track transcript echo suppression.

**Flow:**

- `Sources/amanu/RecordingSession.swift` — starts the system recorder before the mic recorder and records per-track timing offsets.
- `Sources/amanu/Audio/SystemAudioRecorder.swift` — captures the clean far-end reference through an independent Core Audio process tap.
- `Sources/amanu/Transcription/ParakeetEngine.swift` — transcribes each readable audio file.
- `Sources/amanu/Transcription/TranscriptionCoordinator.swift` — shifts and merges mic and system segments.

**Downstream:**

- `Sources/amanu/Transcription/TranscriptionEngine.swift` — defines timed transcript segments and speaker attribution.
