A small release about the two places amanu said something it did not mean. It
waited a minute and a half after every call to be sure the call was over, and
kept that minute and a half. And it described itself as *waiting* while it sat
there perfectly well, which reads as a stall rather than as readiness.

## What changed since v0.4.3

- **The wait before an automatic recording stops is fifteen seconds, not
  ninety.** The ninety was set when the microphone was the only evidence there
  was. Stopping now also requires the far end to have been silent, and that
  pair of conditions does not need a minute and a half to be trusted. Fifteen
  seconds is four consecutive clean samples of the five-second loop — a whole
  tick of margin over what anything shorter would come down to — and it stops
  tacking ninety seconds of nothing onto the end of every meeting. The
  arithmetic that throws short calls away is unchanged and still subtracts the
  wait; it now subtracts a much smaller one. If your Mac is on a call app that
  releases the input device for longer than fifteen seconds mid-call, set
  `stop_delay_seconds` back up in `config.json`.

- **The loop says `ready` rather than `waiting`.** Same state, in the menu and
  in the status window, described as what it is: nothing to record yet, and
  everything in place to record it.

## What this fixes about the last release

v0.4.3 shipped with a warning that the newly-working discard rule would only
fire ninety seconds after the call it discards, and that anyone watching the
timer would think it had failed. That was true, and it is the reason this
release exists. The live checklist has been rewritten to the new number.

## Honest about what is untested

**No meeting was recorded for this release either.** The change is to a
constant and to a string, both covered by the tests around them, and the window
was rendered off screen as usual. The audio path itself still cannot be
exercised without holding a real call, and none was held.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.4-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.4-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.4-macos-universal.dmg`
