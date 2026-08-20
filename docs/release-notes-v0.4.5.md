One fix, to the window that is on screen all day. The checkbox for the live
transcript was being drawn across the Manage recordings button, and it was the
window's own doing: it kept asking to be shorter than the rows it holds.

## What changed since v0.4.4

- **The status window is as tall as what is in it.** Its height was three
  constants — 320×210 idle, 460 with the transcript open, and whatever the
  window happened to be before the transcript borrowed the room — and none of
  them knew about the rows that come and go: the line saying where the
  transcription happens, the line saying why a recording is running, the live
  section itself. With both of those one-liners on screen the content needs 234
  points, the window went on asking for 210, and what came of asking was the
  **Live transcript** checkbox printed across **Manage recordings…**. Every
  change that can add a row now measures the content and grows to it, and no
  resize can ask for less than that. The window still gives the height back
  when the live transcript folds away, and a window you have dragged taller is
  still left at the size you dragged it to.

## Honest about what is untested

**No meeting was recorded for this release.** The change is to one window's
layout arithmetic, and it is covered from both directions: a new test drives
the window through every state it has and fails on the old code — 234 points of
rows in 178 points of window, three times over — and the gallery renders the
window before and after to pixel-identical pictures, so nothing else moved.
The audio path is untouched and, as ever, cannot be exercised without holding a
real call.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.5-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.5-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.5-macos-universal.dmg`
