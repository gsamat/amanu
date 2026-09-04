This release fixes automatic recording restarting during a call after the user
has stopped it by hand.

## What changed since v0.4.14

- A manual stop now suppresses automatic recording until the current call has
  actually ended. Previously the suppression expired after fifteen minutes,
  so a long-running Zoom call could be mistaken for a new meeting and start
  recording again every time that timer elapsed.
- Automatic recording rearms normally after the call app releases the
  microphone for the configured call-end interval, so a later call is still
  recorded.
- Deterministic regression tests cover both staying stopped during the same
  call and rearming for the next one. The complete suite now contains 345
  tests in 41 suites.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.15-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.15-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.15-macos-universal.dmg`
