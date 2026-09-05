# Support

Before reporting a problem, run `amanu doctor` and check
[Troubleshooting](#troubleshooting). Search existing issues, then open a
bug report with the Amanu and macOS versions, what you expected, what happened,
and safe reproduction steps.

Do not attach recordings, transcripts, calendar data, API keys, or unredacted
logs to a public issue. Follow [SECURITY.md](SECURITY.md) for vulnerabilities.

## Troubleshooting

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
- Intel Macs require a cloud transcription key; local Parakeet transcription
  requires Apple Silicon. A universal binary is available, but physical Intel
  hardware has not been validated.
