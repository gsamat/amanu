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
  AssemblyAI detects language separately for the microphone and call, preserving
  Russian speech alongside English call audio; language switching is enabled.
  Long Windows Parakeet tracks are processed in bounded portions with overlapping
  context and meeting-relative word timestamps to limit memory use.
- Recordings management, import, playback, and re-transcription.
- English and Russian interface, Windows light and dark themes.
- The application and installer are named Amanu. Updates use the stable channel.

Local models are downloaded in Settings. Live transcription uses a separate
model of about 750 MB and processes audio on this computer.
