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
  screen reads the file again. The same pass found two places that
  rewrote `config.json` without being asked: the setup window on every redraw,
  and the settings window whenever a field it had never touched lost focus.
- **Smaller things in the same window.** The Access rows are one height rather
  than two. **Keep the audio after transcribing** is a switch like every other
  switch. The parakeet download counts towards 460 MB, which is about what the model
  weighs, rather than 600, which it never reached. And the footer stopped
  saying everything was granted while something on screen said it was not. A
  provider you once looked at without having a key stopped being asked about
  for ever, which had left a key field open over a key that already worked.
  And a row of two lines has its bottom margin back: the last line used to sit
  on the separator under it.
- **`amanu setup` works on a Mac where nothing is running yet** — the branch
  that starts the application itself never worked, which is to say it never
  worked on a fresh install, the one place the README sends people. Fixing it
  turned up something worse: run from a terminal, the application asked the
  system about the terminal's permissions and believed the answers. The
  setup window would show a green tick for a permission amanu did not have,
  and its system-audio test would pass on the terminal's grant and remember
  that for a month. A command run from a shell now opens the application
  properly and lets it answer for itself.
- **Setup is offered only while there is a first run left to finish.** Once it
  is done the menu item goes; `amanu setup` in a terminal is the way back to
  it, and says so in the README. Settings, and the same form on its **Setup**
  tab, are where they always were — and that tab now carries the wizard's own
  sentence about what is left, so somewhere still answers "is everything all
  right" in one line.

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

This release was written by several agents working at once, each on its own
copy, none of them knowing about the others, and merged afterwards. The merge
is the part worth being careful about, so it is worth saying exactly what was
checked and how.

The automated tests pass — 201 of them — the universal build is signed and
both slices answer `doctor`. Every window was rendered off screen in both
appearances and compared frame by frame against the same window before the
merge; that is how two of the layout defects above were found. The transcription
section, both key fields, the two windows that show one form, and the setup
command's handoff to the application were each driven by hand in a running
copy, and four of the fixes above exist because that found something the tests
did not.

What that did not cover:

- **The manual checklist has not been run end to end** against this build.
  `docs/testing/setup-window-manual-checklist.md` is longer than what was
  driven by hand, and the last two fixes went in after the last click-through.
- **Pasting a key that works has not been watched.** A deliberately wrong key
  was, and it is refused without touching the key already on disk. The other
  half of that path — an accepted key turning the cloud switch on by itself —
  needs a real key typed by a person, and nobody typed one.
- **Downloading parakeet from scratch has not been watched** either, because
  the only way to arrange it was to move a working model out from under a
  machine that was using it.
- **OpenAI has never run on an Intel Mac.** The engine was exercised against
  the live API, including a meeting long enough to be sliced, but only on
  Apple Silicon. There is nothing architecture-dependent in it, which makes
  that a prediction rather than a measurement. `docs/old-macs.md` keeps the
  measured and the expected in separate columns, and so does this.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.0-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.0-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.0-macos-universal.dmg`
