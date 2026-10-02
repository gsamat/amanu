# Amanu 0.6.1

## Automatic recording

- The Call apps list now accepts app names as well as bundle-id prefixes. Entries such as Comet and Comet Helper detect the browser's microphone activity and follow its helper processes for audio capture.
- Advanced settings now has an optional Record any app that opens the mic switch, off by default. It keeps dictation tools and ignored apps excluded, and turning it off restores the configured call list.
- Clarified that clearing the Call apps field restores the standard list. The new switch stays in Advanced settings.

## Summaries

- Codex summaries use the model selected in Codex's own configuration. Amanu no longer forces the OpenAI API model onto a Codex subscription, which could make summaries fail. The OpenAI API model setting continues to apply to API summaries.

## Compatibility

- Universal binary for Apple Silicon and Intel Macs running macOS 14.2 or later. Local transcription requires Apple Silicon; Intel requires a cloud transcription key and has not been tested on physical hardware.
