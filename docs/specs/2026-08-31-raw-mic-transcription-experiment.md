# Raw microphone transcription experiment

## Goal

Amanu must not change the sound a person hears when recording starts. Apple
VoiceProcessingIO therefore becomes opt-in instead of the default. The raw
microphone may contain acoustic playback from speakers; transcription removes
that duplication after capture instead of changing the live output route.

The first release is an instrumented experiment. It must leave enough evidence
in each session's `meta.json` to compare transcription results after several
real meetings. Archive fidelity is secondary to an intelligible transcript.

## Capture behavior

- `mic_voice_processing` defaults to `false` in both `Config` and Settings.
- An explicit `true` keeps the existing VoiceProcessingIO path and fallback.
- Ending a recording releases the live-transcription closures that retain the
  recording session, so an explicitly enabled voice route cannot remain alive
  after Stop.
- `meta.json` records a `mic_capture` object containing the requested, initial,
  and final voice-processing state; initial input and output device names; the
  written track's sample rate, channel count, and sample format; and whether a
  voice-processing route fell back to raw capture. Existing `mic_restarts`
  continues to describe every later route transition and its effective mode.

## Transcription behavior

Parakeet remains a per-track engine. It receives mic and system independently,
then `EchoFilter` removes mic segments that duplicate overlapping system
speech.

AssemblyAI becomes a multichannel engine. Amanu aligns mic on channel 1 (left)
and system on channel 2 (right) in `multichannel.m4a`, then submits one request
with both `multichannel` and `speaker_labels` enabled. Current AssemblyAI
responses label speakers `1A`, `1B`, `2A`, and so on. Amanu maps channel 1 to
`me` and channel 2 to `them`, retaining stable A/B suffixes only when a side
contains multiple voices. A new cache filename prevents a response produced by
the old mixed request from being reused as multichannel output.

The multichannel transcript also goes through `EchoFilter`: raw speaker
playback heard by the mic is a `me`-side duplicate of a `them`-side segment.
The filter recognizes suffixed side labels without weakening its conservative
matching thresholds.

OpenAI transcription remains on its existing mixed path in this experiment.
Raw speaker echo may make its side attribution less reliable; that path is not
the configured default on the development Mac and is outside this change.

## Derived audio and failures

- An existing stereo `audio.m4a` is reused directly for multichannel
  retranscription.
- Otherwise Amanu creates `multichannel.m4a` transactionally from the two
  source tracks, using the same alignment and channel assignment as the archive.
- A missing track becomes silence in its channel. An existing but unreadable
  track fails transcription and preserves every source file.
- `multichannel.m4a` is derived data and is removed when audio is settled or
  discarded.
- A network failure may still fall back from AssemblyAI to Parakeet. Metadata
  records the input mode of the engine that actually produced the transcript.

## Experimental metadata

After a successful transcription `meta.json` records:

- `transcription_input`: `per-track`, `multichannel`, or `mixed`;
- `echo_filter`: whether it ran and how many segments it removed.

Together with `transcript.json`, `mic_capture`, and `mic_restarts`, these fields
make real recordings comparable without inferring capture behavior from a
waveform.

## Verification

Automated tests cover the raw default, release of retained recording closures,
capture-metadata serialization, stereo channel construction, AssemblyAI request
flags and response labels, cache separation, multichannel coordination,
suffixed-label echo filtering, diagnostic metadata, and derived-file cleanup.

The full Swift suite must pass. A manual check then records a call through
speakers and one through headphones, confirms that playback does not jump or
remain attenuated, and verifies that both sides appear once in the final
transcript. After normal use has produced several instrumented meetings, the
recordings can be reviewed by capture mode and EchoFilter count.
