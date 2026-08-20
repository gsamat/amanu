One release, about one thing: what happens to a recording when the audio route
changes under it. Plug in headphones, take an AirPod out of your ear, let a
call app take the microphone — each of those rebuilds the capture engine, and
until now the rebuild quietly gave away two things it should have kept.

## What changed since v0.4.5

- **A route change no longer costs echo cancellation.** The rebuild used to
  restart the microphone raw, on the reasoning that during a call the call app
  cancels echo anyway. It cancels echo in what it **sends**; amanu taps the
  device itself, and nothing in the call app's graph has ever seen that tap. So
  from the first route change onward, the microphone wrote down whatever the
  speakers were playing — the far end, on your own track, a second copy of a
  voice that is already on the other one. In the call that prompted this, it
  ran for 35 minutes at 3 dB under the real thing, loud enough that speaker
  attribution put one of their voices on our side of the meeting. The rebuild
  now keeps voice processing, and falls back to raw only if the new route
  refuses it.

- **The track keeps the wall clock across a rebuild.** The dead span was
  written as silence **before** the new engine started, so the few hundred
  milliseconds — sometimes seconds — a device takes to come back were left out
  of the file, and everything after the restart sat that much early. Measured
  against a Zoom cloud recording of the same call: 0.37 s per restart, twice,
  never recovered. The silence is now written by the first buffer of the new
  engine, which is the only thing that knows how long the route was really
  down.

- **Route changes are written into `meta.json`.** Each rebuild is recorded in
  `mic_restarts`: when it happened, how long the gap was, whether echo
  cancellation survived it, and the input and output device on either side of
  the change. None of this was recorded before — the only evidence a session
  had been through one was a short pad in the waveform.

- **A reconfiguration is now judged by whether audio is still arriving.**
  Turning voice processing on reconfigures the input device, which posts the
  same notification a real route change does. Ignoring our own change is not
  safe — sometimes the engine really has stopped — so the decision waits five
  seconds and asks whether buffers are still landing. Found while testing this
  release, by losing 43 seconds of a 67-second recording.

## Honest about what is untested

**Audio was recorded for this one** — five short sessions on an M-series Mac,
with the input device genuinely reconfigured under each of them. Capture came
back with voice processing intact ten times out of ten, the padded gaps matched
the wall clock to within the encoder's rounding (a 51-second session came out
51.37 seconds long, its two pads 4.09 and 4.07 seconds against the 3.94 and
3.88 recorded in `meta.json`), and the last two runs were clean end to end.
What none of that covers: the acoustic half. No call was held, so the echo the
canceller is there to remove was never actually played into the room — the
evidence that it removes it is
the first eleven minutes of the recording that started this, same speakers,
same microphone, cancellation on, nothing audible on the mic track. AirPods
specifically were not part of the test, and neither was Intel.

Known and not fixed here: changing the **default** input device mid-recording
does not rebuild anything, because the engine stays bound to the device it
started on. Pick a different microphone in a call app while amanu is running
and amanu keeps recording the old one.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.6-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.6-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.6-macos-universal.dmg`
