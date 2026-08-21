One change to look at, and one thing that is not in the disk image at all:
amanu now has a page of its own at `https://samat.me/amanu/`, which is where
the download button points.

## What changed since v0.4.9

- **The clock holds still wherever it is drawn.** v0.4.9 gave the menu bar its
  tabular figures, which left the two other places the elapsed time appears
  still twitching once a second: the state line in the status window, and the
  first line of the menu, which ticks for as long as the menu is open. Both now
  ask their own font for the same feature — the numerals set on one common
  advance, the words either side of the clock untouched. The badge on the Dock
  icon is drawn by the system and is not ours to set.

## Honest about what is untested

**No meeting was recorded for this release.** The change is a font feature and
nothing else: the two strings that used to differ by six and a half points now
measure identically in both fonts, and the status window was rendered to PNG to
confirm the rest of the layout sat where it did before. The menu was not
rendered — there is no harness that opens one — so the line that ticks inside
it was reasoned about rather than looked at.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.10-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.10-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.10-macos-universal.dmg`
