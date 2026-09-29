# Amanu for Windows — beta 0.6.0

This is a feature-complete beta for Windows 11 25H2 x64. Calendar integration
is intentionally excluded from the Windows product. The publisher and Azure
Artifact Signing profile will be selected separately; until then, distribute
the unsigned build only to named testers.

## Included in this build

- first-run setup, manual and automatic two-track recording of the microphone
  and a call app, plus pause/resume with timeline-preserving silence;
- Zoom, Teams, Telegram, WhatsApp, Discord, Webex, Slack, and browser process
  detection, with configurable delays, limits, app lists, and ignore lists;
- crash-safe sessions, interrupted-recording recovery, start at sign-in,
  notification-area operation, and single-instance protection;
- recordings browser, audio/video import, transcript and summary viewer,
  audio playback, manual speaker renaming, retry, and full retranscription;
- AssemblyAI and OpenAI cloud transcription;
- downloadable, SHA-256-pinned local Parakeet v3, GigaAM v3, and Whisper
  models through a bundled transcribe.cpp Windows CLI built from a pinned source commit;
- opt-in rolling live transcription with timestamps;
- speaker-name inference with evidence validation and manual-name precedence;
- meeting summaries through OpenAI, Anthropic, or Ollama, including long
  transcript chunking and the same default summary template as macOS;
- cloud-to-local fallback, durable processing queue, three-attempt recovery,
  atomic completion files, transcript echo filtering, audio cleanup or final
  AAC archive, and the configurable post-processing hook;
- Windows Credential Manager storage for API keys;
- the same opt-out, allow-listed technical analytics as macOS, with no audio,
  transcript text, names, paths, keys, or raw error messages;
- Velopack installer, beta update channel, and settings that survive updates.

## Windows-specific notes

- Browser audio is isolated by process tree, not by tab. Other tabs in the
  same browser process tree can be included.
- Live text is produced from completed 20-second fragments. It is deliberately
  behind the conversation rather than claiming word-by-word streaming.
- The local transcription CLI is included in the installer. Models are large
  (about 270–887 MB) and download from Settings when a tester chooses one.
- The app is currently packaged for x64. The code is structured for ARM64,
  but the local transcription runtime used by this beta is x64.
- This source build is cross-compiled and must pass the Windows hardware matrix
  below before wider distribution.
- Until signing is configured, Windows SmartScreen will warn about Setup. Do
  not distribute an unsigned build outside the named tester group.

## Tester checklist

1. Install `Amanu-beta-Setup.exe`, permit microphone access, and leave
   start-at-sign-in enabled. In Windows light and dark app modes, check that
   setup and Settings show the same cards and readable closed/open dropdowns.
2. In Settings, either add an AssemblyAI/OpenAI key or install Parakeet. Add an
   OpenAI/Anthropic key or configure Ollama if speaker names and summaries are
   expected.
3. Make a manual one-minute recording while speaking and playing remote audio.
   Verify that the session appears, transcribes, resolves names when evidence
   exists, and produces a summary.
4. Repeat in Zoom or Teams. Verify start after the configured delay, stop after
   microphone release, and that both sides are present.
5. Enable live transcription and verify that text appears in roughly
   20–40 seconds without interrupting the final transcript.
6. Import one audio or video file, then test retry, full retranscription,
   speaker rename, playback, and opening the session folder.
7. Test with built-in audio, a USB headset, Bluetooth headphones, device change
   during a call, sleep/wake, loss of network, and an app kill followed by
   restart.
8. Send `meta.json`, `transcribe.log` when present, Windows build number,
   headset model, selected providers/models, and a description of any failure.
   Never send meeting audio without participant permission.
