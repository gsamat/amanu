# Stereo audio archive

## Goal

When **Keep the audio after transcribing** is enabled, retain one compact,
playable recording instead of two large PCM tracks. The archive must preserve
who was on each side of the call:

- left channel: the local microphone (`me`);
- right channel: captured system audio (`them`).

The retained file is `audio.m4a`, encoded as AAC with macOS-native audio APIs.
The setup window shows only the checkbox label; it does not show the explanatory
paragraph currently beneath it.

## Recording and settlement flow

Recording itself does not change. A live meeting continues to write independent
`mic.caf` and `system.caf` PCM tracks. PCM is intentionally temporary but is
required while capture is in progress because a hard-killed process can leave
it recoverable without finalizing a compressed container.

After a transcript has been written:

- with `keep_audio` off, discard audio as today;
- with `keep_audio` on, align both tracks on their shared session clock and
  encode them into a single stereo `audio.m4a`;
- write microphone samples to the left channel and system samples to the right;
- represent a missing or late-starting track as silence in its channel;
- update `meta.json` to describe the archive and its channel assignments;
- delete the PCM sources and the derived `mixed.m4a` only after the archive has
  been closed, reopened, and verified and the metadata update has succeeded.

The archive uses AAC at 128 kbit/s. This is small enough for speech archives and
leaves enough bitrate for two independently useful channels.

## Metadata and retranscription

`meta.json` keeps the logical `mic` and `system` identities while recording the
fact that both now live in `audio.m4a` on different channels. Code that prepares
audio for transcription must understand this representation:

- a per-track engine receives a temporary mono extraction of the requested
  channel;
- a mixed/diarizing engine may consume the stereo archive once, downmixed by
  the decoder as needed;
- speaker attribution reads the left and right channels independently;
- temporary extraction files are removed after use.

This preserves the existing **Transcribe again** behavior after the original
PCM tracks have been removed.

## Configuration and UI

`keep_audio` remains the single user-facing choice. When it is enabled, the
archive format is always the compact stereo M4A described above.

The now-redundant `compress_tracks` and `keep_uncompressed` settings are removed
from the settings UI and documented configuration. Old config files may still
contain these keys; they are ignored, so the change does not require a config
migration.

The setup window removes the detail text below **Keep the audio after
transcribing** without replacing it.

## Failure safety

Archive creation is transactional:

1. Encode to a temporary file in the session directory.
2. Close and reopen it and verify that it is readable, stereo, and covers at
   least 99% of the expected shared-clock duration.
3. Atomically replace `audio.m4a` and atomically update `meta.json`.
4. Only then remove source PCM files and derived mixes.

If encoding, verification, or metadata writing fails, remove the incomplete
archive, keep every source PCM file, leave metadata pointing to the sources, and
append the failure to the session log. A failed compression must never cost the
only recoverable recording.

## Tests

Automated tests cover:

- microphone samples appear only in the left channel and system samples only
  in the right channel;
- start offsets become leading silence in the appropriate channel;
- the archive covers the full duration of the longer aligned source;
- the AAC archive is materially smaller than the PCM sources;
- successful settlement updates metadata before deleting PCM;
- unreadable input or failed verification preserves PCM and original metadata;
- discarding removes both old per-track formats and the new `audio.m4a`;
- archived channels can be materialized independently for retranscription.

Manual testing is deferred until the current meeting is over. The checklist
must include recording distinct phrases on each side, confirming left/right
playback, checking disk size, and exercising **Transcribe again** from the
archived M4A.
