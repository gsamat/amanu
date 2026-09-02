This release keeps recording from changing what a meeting sounds like. Amanu
now records the microphone raw by default instead of turning on Apple's duplex
voice-processing route, which could attenuate or interrupt other playback for
as long as the recording ran. Echo is removed from the transcript afterwards,
where it cannot affect the conversation itself.

## What changed since v0.4.10

- **Recording leaves playback alone by default.** `mic_voice_processing` now
  defaults to off. It remains available as an explicit setting when a clean
  archived microphone channel matters more than unchanged playback, but Amanu
  no longer enables VoiceProcessingIO merely to improve transcription.

- **AssemblyAI receives the two sides as separate channels.** Amanu aligns the
  microphone on the left and system audio on the right, and asks AssemblyAI for
  multichannel transcription with diarization inside each channel. The result
  no longer has to guess whether a voice belongs to the microphone or to the
  call from the relative loudness of a mono mix.

- **Raw-microphone echo is filtered more completely.** The text filter still
  keeps genuine cross-talk and short reactions. When AssemblyAI identifies a
  separate microphone speaker whose utterances are overwhelmingly proven to be
  the acoustic copy of system playback, its remaining overlapping ASR
  near-misses are removed too. Speech from that label outside system playback
  is kept.

- **Recordings say how they were made.** `meta.json` now records the requested,
  initial and final microphone processing mode, input and output devices, the
  captured format, the transcription input path, and how many echoed segments
  were removed. Route restarts keep their own processing evidence as before.

- **Stopping a meeting releases the capture route completely.** The live
  transcription coordinator no longer retains closures that keep the finished
  recording session and its microphone engine alive after Stop.

## Checked on real meetings

Two meetings were recorded with voice processing off before this release: a
52-minute Zoom call through the MacBook speakers and a 77-minute Zoom call with
AirPods Pro. Both produced coherent AssemblyAI transcripts and detailed
summaries. On the speaker call the refined filter removes 5,448 duplicate mic
segments, including 353 short fragments the first pass left behind. On the
AirPods call it removes 787 duplicates rather than 679. In both cases the
ordinary microphone speakers stay below the echo-speaker threshold, and speech
outside overlapping system audio is preserved.

The complete automated suite has 305 passing tests. Seven screenshot tests are
skipped outside their visual-test harness.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.11-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.11-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.11-macos-universal.dmg`
