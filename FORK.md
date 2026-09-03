# From quill to Amanu

Amanu began as a fork of
[digimata/quill](https://github.com/digimata/quill) at upstream commit
[`855869e`](https://github.com/digimata/quill/commit/855869e00b18bc9e7e6d171211780b439ce6ccd7).
quill supplied the foundation: a small Swift program that captures the
microphone and Mac audio as separate tracks and transcribes them locally with
Parakeet.

This document records that provenance and the boundary between the projects.
For Amanu's current features and installation instructions, see the
[README](README.md).

## Why it became a separate project

quill is a recorder that runs when asked. Amanu is intended to notice a
meeting, record it safely, and leave behind a useful transcript and summary
without needing supervision.

That change in responsibility affected almost every layer of the program. An
automatic recorder must distinguish a call from any other use of the
microphone, avoid recording unrelated system audio, survive interruption, and
make unfinished work visible and recoverable. A meeting assistant also needs a
real setup flow, durable processing state, and somewhere to inspect and retry
past sessions. Amanu therefore grew into its own application rather than a
small set of patches carried on top of quill.

The new name reflects that scope: an *amanuensis* is a person whose job is to
write down what is said. quill named the instrument; Amanu names the job.

## Where the architecture diverged

### Capture follows the meeting

quill starts and stops manually and captures all audio played by the Mac.
Amanu can also start from per-process microphone activity or a calendar event.
It captures audio from the call application's process family, including helper
processes and call apps that join later, so music, notifications, and unrelated
browser audio stay out of the recording.

Automatic capture also has to handle conditions a manual recorder can leave to
the person operating it. Amanu follows microphone route changes, preserves one
timeline across capture restarts and pauses, and uses separate silence and
duration rules to decide when a meeting has ended.

### Recordings survive interruption

The original recorder wrote AAC into CAF files. CAF itself is
crash-tolerant, but a variable-bit-rate AAC stream still needs packet metadata
written when the file is closed; a hard kill can therefore leave it
undecodable.

Amanu records the live microphone and call tracks as uncompressed PCM. If the
app is terminated or the Mac restarts, the next launch adopts the interrupted
session and returns it to the normal processing queue. After transcription,
the tracks can be archived together as a compact stereo M4A or deleted,
depending on the user's setting.

### A recording is a durable job

Both projects use session folders, but Amanu makes the folder the source of
truth for the whole workflow. Metadata and the presence of output artifacts
describe whether recording, transcription, speaker naming, summarization, or
audio settlement remains to be done. Work is claimed before it starts so the
app and CLI cannot process or upload the same session concurrently.

The pipeline can retry transient failures, defer work that needs a network,
and retire failures that repetition cannot fix. It supports local and cloud
transcription, keeps the two sides of the call attributable, filters proven
echo, assigns names only when the available evidence supports them, and stores
derived speaker names separately from the canonical transcript. Summaries use
the same resumable model: missing tools, exhausted subscriptions, and an
offline Mac do not silently discard the job.

### The daemon became a native application

quill is a menu-bar executable that may run through a LaunchAgent. Amanu ships
as a signed, hardened, and notarized application bundle. The bundle is not only
packaging: macOS associates microphone and system-audio permissions with the
responsible application and its code signature.

Amanu adds first-run setup, Settings, a status window, a recordings browser,
menu-bar and Dock controls, notifications, English and Russian interfaces, and
a CLI installed from the same signed bundle. Sparkle provides signed updates,
with checks and installation gated so an update cannot interrupt an active
recording.

### Failures became regression tests

The test suite was built from observed failure modes: interrupted recordings,
silent tracks, audio-route changes, mismatched sample rates, duplicate work,
transcription fallback, speaker attribution, and UI layout. Window snapshots
cover both interface languages and light and dark appearances.

## What remains from quill

The lineage is still visible in the core constraints:

- one Swift package and one executable, without an Xcode project;
- Core Audio process taps and `AVAudioEngine`, with no meeting bot, virtual
  audio device, or kernel extension;
- separate microphone and call audio, aligned on a shared timeline;
- Parakeet as an on-device transcription engine;
- ordinary session folders rather than a hosted meeting library; and
- the option to keep meeting content entirely on the Mac.

quill was created by Andrew Jones. The ideas above and their first
implementation came from his project. Amanu retains quill's
[MIT license](LICENSE) and upstream copyright notice.

## Following the history

The exact code delta is available in the
[GitHub comparison](https://github.com/gsamat/amanu/compare/855869e00b18bc9e7e6d171211780b439ce6ccd7...master).
Unlike a prose inventory, that comparison stays complete as Amanu changes.

For the reasoning behind particular implementation choices, see
[Things that will bite](docs/pitfalls.md) and the design notes in
[`docs/specs`](docs/specs/). The [release notes](docs/) provide the chronological
record. Together those documents carry details that would make this provenance
note duplicate the rest of the repository and go stale again.
