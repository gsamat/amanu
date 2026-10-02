# Amanu for Windows 0.6.3

- The recording status says **ready** in English and **готов** in Russian
  when no recording is running, in the status window and tray menu.
- Windows and macOS share version **0.6.3**, read from the same `VERSION` file.
  The Windows installer and stable update feed remain separate from macOS.
- Includes the checkbox label fixes shipped in Windows 0.6.2 for the
  Windows light and dark themes.

# Amanu for Windows 0.6.1

- Transcript and summary previews render Markdown headings, emphasis, lists,
  quotes, code, links, task lists and tables. Text can be selected and copied,
  including previews of earlier transcript versions.
- Existing Markdown files display with formatting immediately; meetings do not
  need to be transcribed or summarized again.

# Amanu for Windows 0.6.0

Amanu records meeting audio on Windows 11 x64, transcribes conversations,
and prepares summaries with the configured local or cloud service.

- Manual recording and automatic recording when meeting apps use the microphone.
  Automatic recording starts after three seconds by default on Windows and macOS.
  Short automatic recordings are discarded after stopping; the first 45 seconds
  of a retained meeting are kept.
- Local live transcription of microphone and call audio with the Nemotron streaming model.
  When Live transcript is enabled, its decoders load at startup and remain ready
  between recordings. Turning it off releases them. Idle live decoders allow
  completed recordings to be processed.
- Local and cloud engines for final transcripts, with speaker names and summaries.
  Long Windows Parakeet tracks are processed in bounded portions with overlapping
  context and meeting-relative word timestamps to limit memory use.
- Recordings management, import, playback, and re-transcription.
  Re-transcription shows queued, active, waiting, and failed states for its engine.
  Earlier transcripts remain available during processing and after completion,
  with engine tabs for multiple results and transcript, speakers, and summary tabs
  for the selected result. A single transcript uses only the inner tabs.
- English and Russian interface, Windows light and dark themes.
- The application and installer are named Amanu. Updates use the stable channel.

Local models are downloaded in Settings. Live transcription uses a separate
model of about 750 MB and processes audio on this computer.
