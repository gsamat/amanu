---
title: "A route change doubled the far end and moved the mic track"
date: 2026-08-20
status: done
affects: "the mic track, track alignment, speaker attribution"
---

## Context

`2026.08.20-2001 griffin x samat (zoom.us)`, a 51-minute Zoom call. Partway
through, AirPods connected; three minutes later they came out of an ear and
the source was switched back in Zoom. From that point the far end is audible
on both channels of the archived stereo file, half a second apart.

Zoom recorded the same call to the cloud, which makes the whole thing
measurable: one clean copy of both sides, on a timeline nothing local can
influence.

## Problem statement

Cross-correlating the two tracks in 3-second windows over the far end's own
speech:

| minutes | ρ (peak) | lag |
|---------|----------|-----|
| 0–11    | < 0.05   | +145 ms in the few windows that peak at all |
| 15–20   | 0.40     | −578 ms |
| 21–43   | 0.39     | −547 ms |
| 44–49   | 0.43     | −517 ms |

Three things are wrong in that table.

The far end is on the mic track at all, at −3 to −5 dB against the system
track — loud enough that speaker attribution voted one of the far end's voices
onto our side of the meeting (`speakers.json`: the far end's assistant named
as `me B`).

The lag is negative: on the mic track the copy arrives 578 ms *before* the
audio it is a copy of. Nothing local can do that. The estimated impulse
response is one spike, 47% of its energy inside ±1 ms, magnitude −1 to −4 dB
from 80 Hz to 2 kHz — a room path, not a decoded one, sitting at an impossible
offset.

The lag then moves twice more, 30 ms at a time.

## RCA

**The far end is on the mic track because we turned the canceller off.**
`MicRecorder` restarts capture on `AVAudioEngineConfigurationChange`, and
restarted it with `attach(voiceProcessing: false)`, justified as "during a
call the call app owns echo cancellation". Zoom's canceller works on what Zoom
sends; amanu taps the input device separately, and nothing in Zoom's graph has
ever seen that tap. So the first restart of the session — the AirPods
connecting, at 11:46 — dropped Apple's canceller for the rest of the call, and
when the audio moved back to the speakers three minutes later the mic wrote
down everything they played.

The first eleven minutes prove it was never the room's fault: same speakers,
same mic, same distance, voice processing on, ρ < 0.05.

The Zoom recording proves the call itself was clean — its autocorrelation over
0.15–1.5 s is 0.015, the level of noise, so the far end never heard itself.
The doubling exists only in what amanu wrote.

**The lag is negative because the pad was written before the engine came
back.** `padGapWithSilence` ran in `restartCapture`, between `engine.stop()`
and `attach`, and covered `now − lastBufferAt`. Starting a device takes
hundreds of milliseconds more, and none of them were in the file: every buffer
after a restart was written earlier than it happened, and everything after it
kept that debt. Two restarts, and the mic track sat far enough ahead of the
system track for its echo to precede the echoed.

Measured against the Zoom recording, which is the only clock here that does
not move: the system track holds 55.10–55.17 s behind it for the whole
session, while the mic track steps 55.34 → 55.68 → 56.09 s, once at each
restart, ~0.37 s a time. The digital-zero runs in the mic channel put the
restarts at 706.2 s and 891.3 s, and the second one is also where ρ jumps.

The remaining 30 ms steps are not the restarts; they are the device clock and
the tap clock disagreeing at about 25 ppm, and are not addressed here.

**None of this was recorded anywhere.** `meta.json` said the session was
ordinary. The restarts were only found by looking for zero runs in the
waveform, and the offsets by cross-correlating three files.

## Fix

`MicRecorder`:

- The restart re-attaches with `Config.micVoiceProcessing()`, falling back to
  raw only if the voice graph will not start on the new route.
- `attach(reusingFile:)` takes its client format from the open file rather
  than the new device, so the voice unit can be rebuilt on a device that came
  back at another rate.
- The gap is marked at teardown and written by the first buffer of the new
  engine (`openGap` / `padPendingGap`), which is the only thing that knows how
  long the route really took.
- The liveness check no longer deletes the file when it trips mid-session, and
  waits 3 s rather than 1 s there: the noise suppressor emits true digital
  zeros in a quiet room, in runs that reached 0.87 s in this very recording.
- A change arriving within 1.5 s of an attach may be our own — enabling the
  voice unit reconfigures the device — so the decision waits until 5 s after
  the attach and is made on whether buffers are arriving, not on who is to
  blame. A storm guard drops to raw capture if three restarts land inside 30 s
  anyway.

`RecordingSession` writes the restarts into `meta.json` as `mic_restarts`:
when, how long the gap was, whether cancellation survived, and the input and
output device on either side of the change.

## Found on the way out

The first version of the settle window simply *ignored* a change that arrived
just after an attach, and that is a bug of the same family as the one this file
is about: the notification is also what a stopped engine sends, and there is
nothing in it to tell the two apart. Measured the same evening, on the build
that was about to ship: 43 seconds of a 67-second recording with no microphone
at all, one line in the log saying the change had been ignored, and `meta.json`
reporting a healthy session. Hence the deferred, evidence-based decision above.

Two more things the test runs settled, neither of them fixed here:

- **A default-device change does not reconfigure a running engine.** Switching
  the default input mid-recording — the thing you do when you pick another
  microphone in Zoom — posts nothing, and capture carries on with the device it
  started on. In the call above the restarts came from the AirPods themselves
  arriving and leaving, not from the source being switched.
- **Rebuilding a voice-processing route costs about 4 s** on an M-series Mac
  (0.5 s debounce, the rest the aggregate). Every one of those seconds is
  silence in the mic track. Raw capture comes back in a fraction of it, which
  is presumably why nobody noticed the pad was short.

## Not done

The transcript-level `EchoFilter` still cannot help a session like this one:
it drops mic segments that duplicate system segments, and a diarizing engine
(AssemblyAI here) transcribes one mixed file where there are no sides to
compare. A doubled mic track therefore reaches diarization intact, and
`SpeakerAttribution` votes on channels that already contain each other.

An echo detector — cross-correlate the two tracks after recording, record lag
and level in `meta.json` — would have caught this session on the day rather
than the day after, and is the natural place to decide whether to keep the mic
track in the mix at all.

## Relevant files

- `Sources/amanu/Audio/MicRecorder.swift` — the restart path.
- `Sources/amanu/Audio/AudioDevices.swift` — names for the record.
- `Sources/amanu/RecordingSession.swift` — writes `mic_restarts`.
- `Sources/amanu/Transcription/EchoFilter.swift` — the transcript-level
  fallback, and its limits.
- `Sources/amanu/Transcription/SpeakerAttribution.swift` — what a doubled mic
  track does to the sides.
