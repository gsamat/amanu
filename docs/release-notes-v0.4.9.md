Three small ones, all of them things you look at. The live transcript stops
drawing the whole meeting as two ever-growing paragraphs, the status window
comes to the front when you ask for it, and the clock in the menu bar holds
still while it ticks.

## What changed since v0.4.8

- **The live transcript breaks into blocks again.** The streaming engine does
  not hand over the words it has just decoded — it hands over everything it has
  said since it was loaded, again, on every chunk, and never says where one
  utterance ended. Taken at face value that draws exactly two paragraphs, yours
  and theirs, each growing for the length of the meeting. A side that goes two
  seconds of audio without decoding a word now has its block closed and the
  engine asked to commit, which is what clears the accumulation the next block
  would otherwise be appended to. Two seconds *of audio*, not of clock: a cold
  model can take longer to decode a chunk than the chunk lasts, and a stopwatch
  reads that as a pause and cuts the sentence it is still working through.

- **The status window comes forward.** Asking for it — from the menu, or by
  launching amanu while it is already running — ordered the window to the front
  of amanu's own layer and no further, so a window sitting behind Safari stayed
  behind Safari and the menu item read as having done nothing at all.

- **The clock in the menu bar stops twitching.** The elapsed time beside the
  feather was set in the menu bar's ordinary figures, where every digit has its
  own width, so 1:19 becoming 1:20 changed the length of the item and shifted
  it sideways once a second. It now asks the same font for its tabular figures,
  which is the same face with the numerals on one common advance.

## Honest about what is untested

**No meeting was recorded for this release.** The transcript change is covered
by tests that feed the coordinator the reports the real engine sends, including
the repeat that arrives after a block has been closed and the full stop that
lands a beat after the pause — but a live meeting through a warm model is the
check none of that stands in for, and it has not been done. The window and the
clock are things only a person can see, and neither was seen before this was
cut: the front-most window has no test at all, and the figures were checked by
measuring the two strings in the font rather than by looking at the menu bar.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.9-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.9-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.9-macos-universal.dmg`
