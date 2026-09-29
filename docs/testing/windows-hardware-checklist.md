# Windows: what only a real machine can tell

Everything in `windows/` compiles on a Mac (`dotnet build windows/Amanu.Windows.slnx`,
with `EnableWindowsTargeting`) and the core tests run there
(`dotnet test windows/tests/Amanu.Core.Tests`). Nothing that touches WASAPI,
WPF rendering, the tray, Credential Manager, Velopack or the local
transcription CLI has run anywhere but on Windows, and the 0.6.0-beta.3 rework
(settings, windows, capture, processing) has not run on Windows at all. This is
the list to go through on a Windows 11 x64 machine before the build goes to
anyone.

Each item says what to do and what should happen. "Look" items are the ones a
screenshot answers.

## 0. Build

1. `.\windows\scripts\Build-Beta.ps1 -Version 0.6.0-beta.3` on the Windows host:
   tests pass, the installer is in `windows\artifacts\release`.
2. Install it. SmartScreen warns (unsigned) — expected for the named-tester beta.

## 1. Look: the windows, in both appearances and both languages

The UI is the Windows 11 Fluent theme (`ThemeMode = System`, marked
experimental in .NET 10) plus two drawn controls: the toggle switch and the
choice card (`App.xaml`). Nobody has seen any of it.

1. Settings › Personalization › Colors: light, then dark. Open the status
   window, Settings (both tabs), Setup, Recordings, About, and the tray menu in
   each. Every text readable; switches visibly on (accent colour) or off;
   the selected card has an accent border and a filled dot; no white boxes in
   dark mode; windows have the Mica backdrop.
2. Switch appearance while the windows are open: they follow without a restart.
3. Language: with Windows in Russian, everything is in Russian; set
   `"interface_language": "en"` in Advanced, restart — everything in English.
   Compare the two for rows that wrap differently or get cut off (Russian runs
   about a fifth longer).
4. Settings at its minimum width (700): cards three abreast still readable, no
   horizontal scrollbar.
5. Keyboard only: Tab reaches every switch and card, Space toggles, a focus ring
   is visible on the drawn switch and card.
6. Narrator on the status window and Settings: switches and cards are announced
   by name.

## 2. Settings take effect at once

There is no Save button any more. For each, change it and check it applies
without a restart and that the other surfaces show the same value:

1. Auto-record in the tray menu ⇄ status window checkbox ⇄ Setup tab switch.
2. Recordings folder: choose a new one, record — the session lands there. Choose
   one *during* a recording: the running one finishes in the old folder, the
   line under the path says so.
3. Advanced › Call apps: remove `Zoom.exe`, join a Zoom call — no recording.
   Empty the list — any app taking the mic starts one (Amanu's own capture never
   does).
4. Tray icon off and taskbar icon off: the note about opening Amanu again
   appears; closing the window leaves nothing visible; launching Amanu from Start
   brings the running instance's window back (no second instance, no message).
5. Advanced › a number field: type letters — the old value comes back. Type the
   default — `config.json` loses the key rather than storing it.

## 3. A broken config.json

1. Put `{ broken` in `%LOCALAPPDATA%\Amanu\config.json` while Amanu runs: the
   status window and Settings show the orange explanation, the tray shows a
   notification once, a finished recording is not transcribed ("waiting for
   config.json"), and any switch click says the setting was not saved. The file
   is untouched.
2. Fix the file: within a second or two the warning goes and the waiting session
   is transcribed.
3. Quit, break the file, start: auto-record is off, no analytics, nothing is sent
   anywhere until it is fixed.
4. `"auto_record": { "enabled": "false" }`: Settings names the key and says the
   default applies.

## 4. Recording

1. Manual recording, one minute, speaking and playing call audio: `mic.wav` and
   `system.wav` both non-silent while recording, `meta.json` at stop, the marker
   `.recording.json` gone only after `meta.json` exists.
2. **Alignment across silence.** Record ten minutes where the call is silent for
   the middle five (mute the other side). Loopback capture delivers nothing while
   nothing plays; `TrackWriter` pads the gap from the packet timestamps. Open the
   kept `audio.m4a`: the far side's speech after the silence lines up with your
   replies. This is the single most important audio check.
3. Zoom, Teams (new, `ms-teams.exe`), Telegram, a Chromium meeting: recording
   starts after the start delay, stops after the mic is released plus the stop
   delay; `meta.json` says `app: <process>`.
4. A 20-second join (open mic, leave): the session is discarded — no folder left.
5. `system_audio = all` in Advanced: the next recording captures everything
   Windows plays.
6. Silence backstop (set it to 1 minute): with the call app holding the mic and
   both sides silent, the recording stops as `silence` and does **not** start
   again while the app still holds the mic; it does once the app lets go and
   takes the mic again.
7. Duration ceiling (set 2 minutes): a *manual* recording with auto-record off
   stops at two minutes.
8. Pause/resume: the paused stretch is silence of the right length on both
   tracks.
9. Unplug the USB headset mid-recording, Bluetooth headphones connect/disconnect,
   change the default device: recording continues; the timeline stays aligned.
10. Sleep (close the lid) while recording: the session ends as `sleep` and is
    transcribed after wake.
11. Kill Amanu in Task Manager mid-recording, start it again: the session is
    recovered (notification), its WAV headers are repaired, it transcribes.
12. Make a capture start fail (e.g. exclusive-mode app holding the mic) with
    auto-record on: one notification saying when it retries (30 s, doubling to
    10 min), no empty folders, no stack of notifications.

## 5. Transcription and keys

1. Paste a wrong AssemblyAI key: "refused", not saved. A right one: "key works",
   the field hides, "Replace key…" brings it back. Same for OpenAI, ElevenLabs,
   Anthropic.
2. Credential Manager (Control Panel › Credential Manager › Windows
   Credentials): entries `Amanu/assemblyai`, `Amanu/openai`, …
3. Click OpenAI's card with no OpenAI key while AssemblyAI has one: transcription
   stays on AssemblyAI until an OpenAI key is pasted.
4. Each cloud engine on a two-sided call: speakers come out as me / them, or
   them A / them B with two remote voices.
5. Local: download Parakeet from Settings (progress in MB); cut the network
   halfway — retry resumes rather than restarting. Transcribe with Parakeet,
   Whisper, GigaAM.
6. Engine `parakeet` with the model deleted: the session waits ("isn't
   downloaded") — it must **not** upload. Engine `assemblyai` with no network:
   waits, no attempts used (`processing.json`), transcribes when the network
   returns.
7. `auto` with a cloud key and a local model, network off: falls back to local
   for that session only (`transcribe.log` says so).
8. Recordings › Transcribe again › a specific engine: that engine is used even
   if the queue is busy with others; the old summary shows as "out of date" until
   the new one replaces it; names typed by hand survive.
9. Keep audio on: after transcription only `audio.m4a` is left, stereo, mic left,
   call right. Keep audio off: no audio left. A session whose transcription gave
   up keeps a compressed `audio.m4a` either way.
10. Live transcript on, local model downloaded: lines appear every ~20–40 s labelled
    me / them (я / они); the final transcript is unaffected.

## 6. Names, summaries and where the words go

1. Pick Ollama in Setup, no Ollama running: no transcript goes to Claude or
   OpenAI for names either (the naming pass follows the summary). Summaries off:
   only your own name is filled in.
2. Claude Code installed (native installer or npm): card says "answers · <version>";
   a summary is written through it. Check the process list during the run: it is
   `claude --print … --tools "" …` with a `--system-prompt-file`. (That flag is the
   one Windows-specific assumption about the CLI — if the installed claude
   rejects it, the summary falls to the next backend and `transcribe.log`/the
   session's `summary.deferred` says why.)
3. Codex installed: same, `codex exec --sandbox read-only --ephemeral` with each
   MCP server from `~/.codex/config.toml` switched off.
4. Own key › OpenAI with Base URL `https://openrouter.ai/api/v1`: the key pasted
   goes to `Amanu/openai-compatible`, never to `Amanu/openai`, and vice versa.
5. Ollama Base URL `http://192.168.x.x:11434`: refused with the https
   explanation.
6. Break summaries (wrong model name): after five tries the session shows
   "failed", and it is not retried at every launch; Finish tries again.
7. `on_stop` set to `notepad.exe` with argument `{session}\summary.md`: opens once
   per session, after the summary — not again at the next launch, not twice when
   names were deferred.

## 7. Tray, updates, lifecycle

1. Left click on the tray icon opens the window; right click opens the menu in
   the Windows 11 style, and it closes when clicking elsewhere.
2. The icon gets a red dot while recording, amber while paused; the tooltip shows
   the time.
3. Start at sign-in: sign out and in — Amanu starts with no window (tray on).
4. Quit while recording: the recording is settled (`meta.json`, queued) before
   the process exits. Sign out while recording: same.
5. Check for updates… with a newer beta published: downloads, offers a restart
   only when nothing is recording or processing; settings and sessions survive.

## Where to report

`meta.json`, `processing.json`, `transcribe.log`, the Windows build number, the
headset, which engines and backends, and a screenshot for anything in section 1.
Never meeting audio without the participants' permission.
