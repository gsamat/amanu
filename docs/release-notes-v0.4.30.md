# Amanu 0.4.30

## Automatic recording

- Automatic recording starts monitoring meeting microphone activity immediately, including while first-run setup is open. Microphone permission is still required to begin a recording.
- Calendar authorization no longer delays automatic recording. The default meeting detection delay is now three seconds; an explicitly configured delay is preserved.
- AssemblyAI detects language changes within multilingual meetings, including multichannel recordings.

## Multiple transcripts

- Re-transcribing creates another result without discarding the previous transcript, speaker names or summary. Failed or deferred attempts leave completed results readable.
- Recordings lets you select a transcript version, including repeated runs of the same engine. Transcript, Speakers and Summary show the selected version's own artifacts.
- Previous results are stored in the recording's transcripts folder. The latest result remains at the recording root for existing CLI and hook integrations.
- Removed the unused bottom padding and empty working-status row in Recordings.

## Compatibility

- Universal binary for Apple Silicon and Intel Macs running macOS 14.2 or later. Local transcription requires Apple Silicon; Intel requires a cloud transcription key and has not been tested on physical hardware.
