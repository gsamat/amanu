amanu speaks Russian. On a Mac set to Russian its windows now open in Russian,
without being asked and without anything to switch on. Everything else about
this release is the same as v0.4.0.

## What changed since v0.4.0

- **The windows are translated.** The setup window, the settings window and
  both its tabs, the status and recordings windows, the menu bar, the
  application menu, every setting and its explanation, and the notifications.
- **The Mac decides, and you can overrule it.** amanu reads the language the
  Mac is set to; if there is no translation for it, English. A new
  `interface_language` in the settings — `auto`, `en` or `ru` — overrules that
  and is the only new setting in this release. It is deliberately not called
  `language`: `transcription.language` is what is spoken in the meeting and
  `summary.language` is what the summary is written in, and neither of them
  is this.
- **The names of the languages are not translated.** Under the heading that
  asks which language the meetings are mostly in, the list still reads
  English, Русский, Deutsch — each language
  named in itself, the way macOS names them in Language & Region. A name in
  its own language is findable by the person who needs it even when the rest
  of the window is in one they do not read.
- **The command line stays English.** `amanu doctor`, `--help` and the errors
  are diagnostic output that ends up in bug reports, and half of it is the
  names of things — `parakeet`, `assemblyai`, file paths — which have no
  translation.

## What translating it found

Three places where the program was reading its own words back and deciding
something from them. None of them were visible in English, and no test caught
any of them, because in English the words happened to match.

- A card decided its status was good news by comparing the text with
  "answers", "downloaded", "key works". Translated, every card would have gone
  grey.
- The list of what setup still needs was display text, and something else
  asked it whether it contained "parakeet".
- A redraw cleared a stale key status by comparing it with the word
  "checking…", which after translation it would never have equalled again.

All three now say what they mean instead of matching what they print.

## Honest about what is untested

The English windows are unchanged, and that is measured rather than assumed:
the frames of all 290 views are identical to v0.4.0, and so are the rendered
pictures. The Russian ones were rendered in both appearances and looked at —
nothing truncated, nothing overflowing — and two translations were shortened
to keep it that way.

**The application was not launched.** The one line that asks the Mac for its
language at startup is covered by reasoning and by a test of the function it
calls, not by a running copy. The status and recordings windows were measured
to fit but not seen: the tool that renders windows off screen does not render
those two.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.1-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.1-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.1-macos-universal.dmg`
