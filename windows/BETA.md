# Amanu for Windows — beta 0.6.0

A beta for Windows 11 x64. Calendar integration is deliberately not part of the
Windows product. GitHub Actions test builds are signed as Fands Software LLC
through Azure Artifact Signing. They can be downloaded as Actions artifacts
without publishing a GitHub Release; see [README.md](README.md).

## Fixed since beta.3

- The Setup and Settings windows fit a small screen, with their title bars on
  it; opening Amanu again brings the running window forward.
- Russian (and any other non-Latin) speech transcribed on this computer no
  longer comes out as mojibake.
- Switches and cards changed through Narrator, Voice Access or any other UI
  Automation client now save, as a click does.
- With nothing set up to write summaries, a meeting waits for a model and says
  so, rather than using up its attempts on an Ollama nobody installed.

## New in beta.3

- **Settings like the Mac's.** The setup form and Settings are one form with
  the macOS sections, order and wording; every switch takes effect at once — no
  Save button, no "after a restart". The Advanced tab lists every other setting
  with a line saying what it does and its default shown in the empty field.
- **Windows 11 look.** The Fluent theme: Mica, the system accent colour, light
  and dark following Windows; a tray menu in the same style; a left click on the
  tray icon opens the window; opening Amanu again brings back the running one.
- **English and Russian**, following the Windows display language, or
  `interface_language` in Settings.
- **Where meeting content goes is decided in one place.** Naming speakers follows
  the summary's choice and asks no model when summaries are off; a local engine
  never uploads; the OpenAI key is only sent to OpenAI and a compatible server
  (OpenRouter, Groq) has a key of its own; plain http is only accepted on this
  computer.
- **Summaries through Claude Code or Codex** on an existing subscription, run as
  text completions with no tools, settings or MCP servers.
- **ElevenLabs Scribe** as a third cloud engine; remote voices are told apart
  (them A, them B).
- **A broken config.json no longer resets settings.** The last good settings stay
  in force, nothing is written over the file, transcription waits, and it
  recovers the moment the file is fixed.
- **Recording**: the call track stays aligned through silence and device changes;
  short automatic joins are discarded; a backstop stop no longer re-arms while
  the app still holds the mic; failing starts back off; the duration ceiling
  applies to manual recordings; sleep and sign-out end a recording cleanly; a
  killed recording's WAV headers are repaired on recovery.
- **Processing**: a missing key, model or network never uses up a session's
  attempts; an empty track is a silent side; re-transcription can pick the
  engine, drops cached results and keeps the old summary marked out of date;
  names and summaries give up after five tries; `on_stop` runs once.
- **Recordings window**: status per meeting, summary, transcript and speakers in
  one place, names editable, Finish / Transcribe again / Listen / Delete (to the
  Recycle Bin).

## Windows-specific notes

- Browser audio is isolated by process tree, not by tab.
- Live text comes from completed 20-second pieces, transcribed by the local model
  when one is downloaded and by the configured cloud engine otherwise.
- The local transcription CLI ships in the installer; models (270–890 MB) download
  from Settings and resume if interrupted.
- x64 only for now; the code is architecture-neutral.
- API keys live in Windows Credential Manager (`Amanu/…`).

## Tester checklist

[`docs/testing/windows-hardware-checklist.md`](../docs/testing/windows-hardware-checklist.md)
is the full list. The short version:

1. Install, allow the microphone, look at Setup in light and dark.
2. Add an AssemblyAI/OpenAI/ElevenLabs key or download Parakeet; pick a summary
   route (Claude Code, Codex, a key, or Ollama).
3. A manual one-minute recording, then a Zoom or Teams call: both sides present
   and aligned, transcript, names, summary.
4. A device change, sleep, and killing Amanu mid-recording.
5. Send `meta.json`, `processing.json`, `transcribe.log`, the Windows build,
   the headset, engines and backends. Never meeting audio without permission.
