The setup window asks better questions. Transcription is now two switches
rather than three cards, there is a second cloud engine to choose between, the
meeting language is a list of languages instead of a two-letter code — and
naming one no longer forces the engine to hear it.

## What changed since v0.3.0

- **Transcription asks what you want, not which engine.** Two switches,
  **In the cloud** and **On this Mac**. Both on is the old fallback — the cloud
  when it answers, this Mac when it does not — so there is no card for it now.
  Both off turns transcription off. Under the cloud switch are the two
  providers with what they cost per hour, and pasting a working key turns the
  switch on by itself.
- **OpenAI is the second cloud engine**, alongside AssemblyAI. Nothing changes
  unless you pick it: the default provider is the one you already had, an
  older `config.json` is read exactly as before, and the key is looked for in
  `~/.config/amanu/keys/openai`, `OPENAI_API_KEY`, or the shared
  `~/.config/openai/` files, which amanu reads and never writes.
- **A named meeting language stopped being a pin.** Setting the language to
  Russian used to tell parakeet to refuse Latin letters, so an English meeting
  came back as fluent-looking Cyrillic nonsense — and, with **Keep the audio**
  off by default, came back that way for good. The setting now reads as
  **expect this language, and English**, and leaves the engines to hear which
  one it actually was. The cloud engines were fixed the same way.
- **The language is chosen from a list.** Every language parakeet knows, named
  in itself, behind **Detect automatically**. No two-letter codes anywhere in
  the window.
- **The Calendar button in setup works.** It did nothing at all before —
  silently, because the hardened runtime closes EventKit to an application
  whose signature does not ask for it, and the bundle never did. See below for
  what this means on first launch.
- **Settings shows the setup form itself**, on a **Setup** tab, rather than a
  second and poorer list of the same keys. **Advanced** is still the complete
  schema, and every field now shows its own default in grey rather than an
  example that was sometimes untrue. Both windows open at the top of the form,
  which the settings one did not: it opened partway down the list.
- **The window survives the light theme.** Its borders and separators were
  resolved to fixed colours once, when it was built, so switching appearance
  left the previous theme's lines behind — pale grey on white, or white on
  dark. They are re-read now, and a window built before it has one no longer
  guesses.
- **Every window follows a change to a setting.** The setup form now lives in
  two places at once, and the settings window has a second tab besides, so a
  provider switched in one used to leave the others showing what was true a
  minute ago. Anything that writes a setting now says so, and everything on
  screen reads the file again. The same pass found the setup window rewriting
  `config.json` every time it redrew itself.
- **Smaller things in the same window.** The Access rows are one height rather
  than two. **Keep the audio after transcribing** is a switch like every other
  switch. The parakeet download counts towards 460 MB, which is about what the model
  weighs, rather than 600, which it never reached. And the footer stopped
  saying everything was granted while something on screen said it was not. A
  provider you once looked at without having a key stopped being asked about
  for ever, which had left a key field open over a key that already worked.
  And a row of two lines has its bottom margin back: the last line used to sit
  on the separator under it.

## The calendar dialog, once, on first launch

amanu asks for the calendar a few seconds after it starts, without waiting for
anyone to press anything: it names recordings after the meeting they belong to
and it can start recording on schedule. That request has always been made and
has always failed on the hardened runtime, so nobody ever saw it. Now it will
appear — once, shortly after the update, for everyone.

Refusing it costs nothing that was working yesterday: recordings are named by
time instead, and automatic recording still starts from the call applications
themselves. The Calendar row in setup offers **Open Settings** if you change
your mind.

Nothing else needs granting again. The microphone and system-audio permissions
are keyed to the signing identity, which has not changed, and they survive this
update as they survive any rebuild.

## Honest about what is untested

The whole of this release was written by several agents working at once and
merged afterwards, and the merge is the part worth being careful about. The
automated tests pass — 188 of them — the universal build is signed and both
slices answer `doctor`, and each window was rendered off screen and looked at.
But **nobody has clicked through the merged setup window in a running copy**,
and `docs/testing/setup-window-manual-checklist.md` has not been run against
this build.

**OpenAI has never run on an Intel Mac.** The engine was exercised against the
live API, including a meeting long enough to be sliced, but only on Apple
Silicon. There is nothing architecture-dependent in it, which makes that a
prediction rather than a measurement. `docs/old-macs.md` keeps the two apart.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.0-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.0-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.0-macos-universal.dmg`
