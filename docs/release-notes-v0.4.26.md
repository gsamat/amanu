# Amanu 0.4.26

## Transcription

- Transcription no longer gets stuck after acoustic echo cancellation on macOS Tahoe. Amanu now lets Core Audio choose an AAC bitrate supported by the resulting 16 kHz tracks.
- Live transcription hides an echoed microphone phrase even when the cleaner call audio was split into several blocks or arrived through the decoder with a different delay.
- ElevenLabs Scribe v2 is available as a transcription engine. Amanu processes the microphone and call audio separately, retaining distinct speakers on each side.
- AssemblyAI transcripts now group word-sized fragments into readable paragraphs while preserving speaker changes and pauses. Existing transcripts can be reformatted from saved data without sending the audio again.

## Automatic recording

- Calls in DION now start automatic recording. Amanu recognises both the main DION app and its helper processes.

## Recordings

- Open a transcript directly from the recordings window in your preferred Markdown app. If no app is associated with Markdown, Amanu opens it in TextEdit.
- Open the selected recording folder directly from the same window.

## Compatibility

- Universal binary for Apple Silicon and Intel Macs running macOS 14.2 or later. Local transcription requires Apple Silicon; Intel requires a cloud transcription key and has not been tested on physical hardware.
