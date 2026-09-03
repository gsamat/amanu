This patch release fixes a race found by Amanu's new clean GitHub Actions run.

## What changed since v0.4.13

- An explicit analytics flush now waits for a request that the background
  timer has already started. Previously it could return early while that
  request was still in flight. Failed events were still persisted for retry,
  so this did not affect meeting content or recordings.
- A deterministic regression test covers the in-flight send path. The complete
  suite now contains 343 tests in 40 suites.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.14-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.14-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.14-macos-universal.dmg`
