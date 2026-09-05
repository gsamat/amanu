This release protects recordings and transcripts when processing fails, fixes
analytics consent, and makes setup and command-line model processing more reliable.

## What changed since v0.4.15

- Echo filtering preserves substantive local replies even when the same speaker
  label was previously assigned to playback echo.
- A failed track or an empty transcription no longer produces a successful
  completion marker. Audio is kept for another attempt. Recording-only mode
  archives the audio without discarding the sole copy of the meeting.
- Command-line summary and speaker-naming tools cannot hang indefinitely on
  blocked input or output. Deadlines and cancellation stop the child process,
  and timeouts remain eligible for retry.
- Denied microphone permission reopens setup instead of silently closing the
  app. A successful sound test no longer marks the whole setup as completed.
- Quitting from the menu bar now asks for confirmation while recording.
  Ordinary silence at the beginning of a call no longer triggers an immediate
  warning about system-audio permission.
- Analytics can be enabled after an opted-out launch, and disabling it from
  the command line is respected by the running app before further collection
  or sending. Pending events are cleared; requests already sent cannot be recalled.
- Analytics delivery preserves new events when the queue fills during a
  request, retries temporary HTTP failures, and replaces arbitrary engine,
  backend and trigger strings with a fixed value.
- Privacy explanations and troubleshooting have been clarified. The release
  checks now cover a clean checkout and both processor architectures.
- Validation: 364 Swift tests, 9 Python tests and the landing-page checks pass.

## Requirements

macOS 15 or later. The app includes Apple Silicon and Intel binaries; local
Parakeet transcription requires Apple Silicon, and Intel requires a cloud
transcription key. Physical Intel hardware and macOS 15 have not been tested.
The app is signed with Developer ID and uses the hardened runtime. The disk
image carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.16-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.16-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.16-macos-universal.dmg`
