The other half of v0.4.6. That release taught the recording to survive a route
change; this one teaches it to notice one. Until now the microphone was
whichever device happened to be the default when the engine started, and it
stayed that microphone whatever you did afterwards.

## What changed since v0.4.6

- **The mic track follows the microphone you are actually talking into.**
  Change the default input mid-meeting and nothing used to happen — no
  notification, no error, the same device in the file as before, for the rest
  of the call. There is now a listener on the default input, and the track
  moves with it: about three seconds from the change to the new microphone,
  written down in `mic_restarts` like any other route change.

- **And it follows the call rather than the system.** The default is an
  approximation: pick another microphone in Zoom's own settings and the system
  default does not move, so a recording that follows the default is still on
  the wrong one. amanu now asks Core Audio which device the call app is
  listening to — the same question the far-end tap already asks about output —
  and records that, falling back to the default when there is no answer. The
  answer is re-asked every fifteen seconds, because a call app can change
  device without anything system-wide changing at all.

- **An engine that has stopped is rebuilt at once.** v0.4.6 waited five seconds
  before deciding whether a configuration change had killed capture or was
  merely its own doing. The engine can be asked directly whether it is still
  running, so the dead case no longer costs the wait — and the liveness check
  no longer counts a buffer from the engine that has just been torn down as
  evidence about the one replacing it.

## Honest about what is untested

Live, on an M-series Mac: the default input was switched under a running
recording, twice, and capture moved with it — 2.8 seconds of silence per move,
voice processing intact, both devices named in `meta.json`. A stand-in call app
holding a **non-default** microphone was recorded from that microphone rather
than from the default, and the periodic re-ask is what caught it when the
binding did not take on the first attempt.

Still not covered: AirPods specifically, a real call app rather than a stand-in
one, Intel, and the acoustic half — no meeting was held, so the echo
cancellation this all exists to preserve was again never given an echo to
cancel.

One measurement from the last release deserves a correction. The claim that a
default-device change goes unnoticed was first "measured" with a switch that
never happened: macOS refuses to make Zoom's hidden virtual device the default,
`AudioObjectSetPropertyData` returns success anyway, and the default stays put.
Redone against a temporary aggregate device, the conclusion held — but the
first run proved nothing.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.7-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.7-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.7-macos-universal.dmg`
