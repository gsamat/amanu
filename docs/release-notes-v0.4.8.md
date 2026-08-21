Two things. The status window was drawing one row on top of another, and the
release meant to fix that fixed the wrong half of it. And amanu's two icons —
the feather in the menu bar and the one in the Dock — can each be switched off
now, from the setup form, which is where a question about where a program shows
up belongs.

## What changed since v0.4.7

- **The status window's rows cannot disagree with the window they are in.**
  v0.4.5 made the window grow to whatever its rows need, which was true as far
  as it went and did not go far enough: a running copy was found with the rows
  laid out for a window 22 points shorter than the one they were in, the **Live
  transcript** checkbox drawn across **Manage recordings…**, and resizing the
  window from outside moving nothing at all. The rows were a stack view put
  straight into the window's content view, which means they were sized by their
  own constraints rather than by the window, and the two had stopped agreeing.
  They now hang from the top of an ordinary view that resizes with the window,
  and the constraint that stretches them to the bottom — the one the live
  transcript grows into — gives way rather than squeezing two rows into one
  place. Also: the transcription line no longer sits there blank from launch on
  a Mac that has nothing to transcribe, which is where the 22 points came from.

- **The menu bar icon and the Dock icon each have a switch**, two rows under
  *Where amanu shows up* in the setup form, which is also the first tab of
  Settings. The Dock icon was already a setting, buried in Advanced and taking
  effect only at the next launch; the menu bar had none at all. Both apply as
  you click them, which is what makes them safe to offer — turning off the last
  icon leaves a program with nowhere to click, and someone who has just done
  that by accident can undo it in the window they are already standing in.
  With both off amanu goes on recording with nothing on screen, and the way
  back is to open Amanu again. `menu_bar_icon` joins `dock_icon` in
  `config.json`.

## Honest about what is untested

**No meeting was recorded for this release.** The window fix was found by
reading the running application's layout through the accessibility API — that
is what identified the frozen layout, and the same measurements are now a test
that walks the window through every state it has and checks that each row sits
exactly under the one above it. The switches for the two icons are covered by
tests and by the setup window's manual checklist, and the activation-policy
change they make is one only a person can really see.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.8-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.8-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.8-macos-universal.dmg`
