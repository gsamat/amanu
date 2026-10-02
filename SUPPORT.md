# Support

Before reporting a problem, check [Troubleshooting](#troubleshooting). Search
existing issues, then open a bug report with the Amanu version and macOS version
or Windows build, what you expected, what happened, and safe reproduction steps.

Do not attach recordings, transcripts, calendar data, API keys, or unredacted
logs to a public issue. Follow [SECURITY.md](SECURITY.md) for vulnerabilities.

## Troubleshooting

### macOS

Run `amanu doctor` to check permissions, engines, and configuration.

- If microphone permission was denied, open Amanu's setup and grant microphone
  access in System Settings → Privacy & Security. Relaunch after changing it.
- For a silent system track, check the call's audio output and **Screen &
  System Audio Recording** permission. A silent opening does not by itself
  prove the permission is missing. Use the deliberate sound test in setup.
- If an app-scoped system track misses your call, select all system audio in
  Settings and repeat the sound test.
- A failed transcription keeps its audio. Check the session's `transcribe.log`
  locally, correct the backend/key problem, then use Re-transcribe. Avoid
  posting the log publicly without removing personal information.
- If `~/.config/amanu/config.json` stops being valid JSON — a hand edit with
  a stray comma — Amanu keeps recording but holds transcription and
  summaries, sends no statistics, and refuses to save settings over the file.
  Everything else keeps to the settings it last read from the file (if it
  never could, the defaults, with auto-record off). The menu, the windows and
  `amanu doctor` say so. Fix the file, or move it aside to start from the
  defaults; the held recordings are picked up as soon as it can be read.
- Intel Macs require a cloud transcription key; local Parakeet transcription
  requires Apple Silicon. A universal binary is available, but physical Intel
  hardware has not been validated.

### Windows

- Check Windows Settings → Privacy & security → Microphone, including access
  for desktop apps. Use Amanu's Settings to check the selected audio device.
- Closing the window leaves Amanu in the tray. Open it from the tray or Start
  menu; use Quit to stop it.
- If a summary CLI says Not installed or Not signed in, use its Install/Sign in
  control in Settings. Supported desktop-bundled CLIs are detected, but their
  subscription login may be separate from the chat app's login.
- Download the selected final-transcript model and the separate live model
  before offline use. For local summaries, check that Ollama is running and
  has the selected model.
- If configuration is unreadable, fix `%LOCALAPPDATA%\Amanu Data\config.json`.
  Amanu preserves the file and waits to resume processing. There is no Windows
  `amanu doctor` command.
- Use Finish or Transcribe again in the recordings window after correcting a
  missing key/model/network problem. Recordings default to
  `%USERPROFILE%\Amanu Recordings`. Review logs locally before sharing.
- Portable and Scoop copies do not update themselves. Install a newer portable
  package or use Setup for stable-channel automatic updates.
