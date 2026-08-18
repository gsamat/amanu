# Live transcription design

## Purpose

Amanu should optionally show a local transcript while a meeting is still being
recorded. The live text is a disposable preview; the existing Parakeet pass
after recording remains the canonical transcript.

The feature is opt-in during setup, can be turned off and back on while a
recording is running, and must never make audio capture less reliable.

## Product decisions

- NVIDIA Nemotron 3.5 ASR Streaming Multilingual 0.6B provides the live text.
- Parakeet TDT v3 continues to produce `transcript.json` after the meeting.
- The live model uses FluidAudio's 1120 ms Core ML variant. This is true
  cache-aware streaming and gives punctuation more context than the 560 ms
  variant without the visible delay of the 2240 ms variant.
- Microphone and system audio are transcribed as independent streams. They
  share one loaded model bundle but retain separate decoder and encoder-cache
  state, so speaker identity remains `You` and `Them` without diarization.
- Live text is held in memory only. It is not written into the session folder
  and is never treated as a fallback final transcript.
- Enabling live during an existing recording starts at that instant. It never
  reads or catches up from the already-written CAF files.
- Disabling live freezes the text already on screen. Re-enabling adds a
  `Live resumed` boundary and starts a fresh streaming epoch at the current
  instant.
- The user's checkbox choice is persistent and becomes the default for later
  meetings.

## Setup experience

The Transcription section gains a checkbox row below the existing engine,
language, and keep-audio choices:

> **I want to see a live transcript during meetings**  
> An additional local NVIDIA model of about 600 MB will be downloaded. Audio
> never leaves this Mac.

The model is NVIDIA's, while the Core ML package used by FluidAudio is hosted
by FluidInference on Hugging Face. The copy deliberately does not claim that
the bytes come directly from an NVIDIA website.

The setting is stored as `live_transcription.enabled`; its default is `false`.
Checking it starts the model download immediately and shows measured cache
growth as progress, following the existing Parakeet setup pattern. A completed
cache shows `downloaded`. A failed download shows the error and a retry action.

When live transcription is selected, the setup window's normal `Done` path
treats an absent model as unfinished work and starts or retries the download.
`Later` remains an escape hatch and may close setup while the model is absent.
Unchecking the option cancels the active download when cancellation is safe;
already cached files are retained.

The main window does not silently begin a 600 MB download during a meeting. If
the preference is on but the model is absent or corrupt, the live section
explains that setup must download it. Recording and final transcription
continue normally.

## Main-window experience

The status window becomes vertically resizable and gains a `Live transcript`
section at the bottom. The section header contains the persistent checkbox and
an unobtrusive status label.

- While idle, the transcript body is collapsed. The checkbox remains
  available so the next meeting's default is visible and editable.
- At recording start, an enabled section expands and first shows
  `Loading local model…`.
- Transcript blocks show `You` and `Them`, wrap naturally, and are ordered by
  their audio timestamps.
- The latest provisional words may be revised in place. A partial update must
  never append a duplicate copy of the manager's cumulative transcript.
- The view follows new text while it is already at the bottom. Scrolling up
  suspends auto-scroll until the person returns to the bottom.
- Turning the checkbox off stops new model input immediately but leaves the
  existing text visible with a paused status.
- Turning it back on inserts a quiet `Live resumed` divider and appends a new
  epoch. Nothing from the disabled interval appears later.
- Amanu's existing recording pause also pauses live input, then resumes the
  same live epoch when recording resumes.
- At meeting stop, the preview remains visible for reference. It is cleared at
  the beginning of the next recording or when the process exits.
- A live failure appears inline. It never changes the recorder's state or the
  post-recording queue.

## Components

### Live model store

`LiveTranscriptionModelStore` owns cache discovery, download, progress, and
shared model preloading. It uses
`StreamingNemotronMultilingualAsrManager.downloadVariant` and
`preloadShared`, pins the model to FluidAudio's Neural Engine configuration,
and exposes testable states: absent, downloading, ready, and failed.

The selected language comes from `transcription.language`. A known two-letter
code is converted to the model's BCP-47 prompt (`ru` to `ru-RU`); an absent or
unrecognised value uses `auto`. Russian selects the full multilingual model
directory rather than the Latin-vocabulary build.

### Audio buffer relay

`MicRecorder` and `SystemAudioRecorder` gain optional post-mute buffer sinks.
The file write stays first and authoritative. When no sink is installed, the
recorders perform no live-specific copy or allocation.

An installed sink copies the borrowed Core Audio buffer and yields it to a
bounded per-source queue without awaiting on the audio callback. Each queue
holds at most five seconds of audio. Model work, resampling, UI work, and
logging never run on the real-time audio thread. If a queue overflows, live
transcription stops with a `cannot keep up` error rather than growing memory or
delaying recording.

While recording is active, the sink receives the same effective audio that is
written to the track. Recording pause closes a relay gate before the recorders
begin writing silence, so paused buffers are not sent to Nemotron. Resume
reopens the gate without replacing the sink or resetting model state.

### Live transcription coordinator

`LiveTranscriptionCoordinator` is an actor owned by `AppController`. It owns:

- one shared Nemotron model bundle;
- one independent streaming manager for mic and one for system audio;
- the two bounded audio consumers;
- the current streaming epoch number;
- revision-safe transcript state for each source;
- a main-actor update callback for the status window.

The coordinator starts only when both a recording and the live session setting
are active. Turning live off detaches recorder sinks synchronously, increments
the epoch, drains queued buffers without processing them, and resets both
stream states. Results carrying an older epoch are ignored. The shared model
bundle remains resident until that meeting ends so a re-enable is immediate.

Each source's callback is cumulative. The coordinator keeps a committed prefix
and a mutable tail, replaces that tail when Nemotron revises it, and freezes it
at an epoch boundary. Token timestamps plus the recording track's first-buffer
offset provide a shared clock for ordering mic and system blocks. Punctuation
and a one-second speech gap define readable block boundaries; a 60-word cap
prevents an unpunctuated speaker from producing an unbounded block. The UI
never performs text diffing itself.

### Lifecycle integration

At recording start, the window clears the prior preview and the coordinator
starts asynchronously when the saved preference is enabled. Audio capture does
not wait for model loading.

At recording pause, live input pauses without resetting the model. Resume
continues the same epoch. A user checkbox toggle is different: it ends the
epoch and a later toggle creates a new one.

At recording stop, the recorders finalize their files first. Amanu then stops
live consumers, rejects late callbacks, releases both managers and the shared
model bundle, and only then enqueues the directory for the existing Parakeet
pipeline. This avoids keeping roughly 1.5 GB of live model memory resident
while Parakeet loads. The displayed strings are ordinary view state and may
remain after model release.

If the app terminates or crashes, the preview is lost by design. Existing CAF
recovery and post-recording transcription behavior remain unchanged.

## Failure isolation

Every live failure is contained inside `LiveTranscriptionCoordinator`:

- Missing model: show setup guidance and do not attach sinks.
- Load failure: show the error and leave recording active.
- One stream fails: stop the live session as a whole so the UI does not imply
  that a one-sided preview is complete.
- Queue overflow: detach both sinks and report that live could not keep up.
- Late in-flight result: discard it by epoch number.
- Cleanup failure: log it, release owned references, and still enqueue final
  transcription.

No live error increments the post-recording transcription attempt count,
modifies session metadata, stops recording, or deletes audio.

## Testing

Model and recorder integration points are protocol-backed so unit tests use a
fake streaming engine and downloader rather than loading Core ML assets.

Automated tests cover:

- configuration default and persistence from both setup and main window;
- setup absent/downloading/ready/failed/retry states;
- enabled-at-start and enabled-mid-recording behavior;
- no replay of audio captured before enable or while disabled;
- text preservation on disable and `Live resumed` on re-enable;
- stale-result rejection across epoch changes;
- cumulative-partial revision without duplicate text;
- mic/system labelling and timestamp ordering;
- recording pause and resume without an epoch reset;
- bounded-queue overflow and model errors without recorder interruption;
- missing-model behavior without an in-meeting download;
- model release before the Parakeet enqueue begins;
- no live buffer copies while the sink is absent.

The existing full Swift test suite must continue to pass. A manual checklist
will verify model download and retry, real mic/system text, live toggle and
pause during a recording, scroll behavior, window resizing, and successful
final Parakeet output after live use.

## Acceptance criteria

- A setup opt-in downloads and verifies the additional model with visible
  progress.
- With the option enabled, both sides of a meeting appear locally in the main
  window within roughly two seconds on supported Apple Silicon hardware.
- Live can be disabled and re-enabled during a recording with the agreed
  epoch semantics.
- Recording remains gap-free when live is slow, unavailable, or failing.
- Nemotron is released before the canonical Parakeet pass starts.
- No audio or live text leaves the Mac through this feature.
- The neighboring worktrees and their branches are not modified.
