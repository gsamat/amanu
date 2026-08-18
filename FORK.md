# What this fork changed, and why

amanu began as [digimata/quill](https://github.com/digimata/quill) and is now
about 7,800 lines away from it across 54 files. This is the honest account of
what moved and what the reasons were, because a fork that doesn't say what it
did is just a copy with a new name.

## Why fork at all

quill is a good starting point and a stalled one. Its last commit is 30 July
2026, and fourteen pull requests are open against it with nobody merging them.
Nothing here is a complaint about the original — it does what it says: two
tracks, a menu bar item, local transcription. It just stops well short of
"record my meetings and leave me the notes", and the distance turned out to be
mostly in the parts nobody writes for a demo.

The name changed with the scope. *Amanuensis* is the person who writes down
what is said; quill was the object, amanu is the job.

## The part that mattered most: it records by itself

quill records when you click. amanu records when a meeting happens, and that
one change pulled in most of the rest.

Two independent triggers: a call app holds the microphone, or a calendar event
starts. Both are narrower than they sound, and the narrowing is the work.

- **A whitelist of call apps, not a blacklist.** Dictation software, Voice
  Memos and a browser tab metering input levels all open the microphone. On a
  blacklist every one of them is a recording of whatever was in the room until
  someone notices.
- **Microphone use is detected per process, not per device.** Otherwise amanu's
  own capture reads as an ongoing meeting and sustains itself. The predecessor
  project did exactly this and produced fifteen hours of overnight audio.
- **The far end going quiet ends the call** — but only because the audio tap is
  pointed at the call app rather than at the machine (below). Requires macOS
  14.4 for per-process attribution; below that auto-record refuses to run
  instead of guessing.

## Tapping the call app, not the whole Mac

quill taps everything the Mac plays. amanu taps the bundle-id family of the
app that holds the microphone — Chrome renders call audio in a helper process,
Zoom and Teams each ship several — and picks up any other call app that joins
later, because clicking a Zoom link during a browser call is ordinary.

Two things come out of it. The transcript stops collecting music, notification
dings and the video you opened afterwards. And "the far end has gone quiet"
starts meaning *the call ended*: with a global tap, a video opened after a
meeting kept one recording alive for ten extra minutes. Measured both ways —
narrow tap, 92 seconds after the last speech, exactly the configured delay.

## Recording that survives being killed

quill's README says CAF needs no finalization and loses nothing on a crash.
That is true of PCM and **false of AAC**, which is what it wrote: AAC is
variable-bitrate, so the file is undecodable without the packet table written
at close. `kill -9` mid-meeting left 99 KB and zero recoverable seconds.

So amanu records uncompressed PCM — about a gigabyte an hour — and re-encodes
to AAC only once the transcript exists, deleting the PCM after `meta.json`
already points at the new stereo archive. It handles SIGTERM, because logging out,
rebooting and `launchctl kickstart -k` all send one and all used to take the
meeting with them. And a session left behind by a crash is adopted on the next
launch rather than orphaned.

## Transcription that finishes

quill has parakeet. amanu keeps it, adds AssemblyAI behind the same protocol,
and spends most of its new code on the question of what happens when a
transcript doesn't arrive.

- **`auto` picks the engine when there is work**, not at launch: the laptop
  that recorded a meeting on a train is transcribing it on a train. Key plus a
  network means cloud; anything else means local. A connection that drops
  between the probe and the upload falls back to parakeet rather than failing.
- **The queue is the filesystem** — a session with `meta.json` and no
  `transcript.json` is pending — so it survives a restart.
- **A session that can't be transcribed is retired**, after three attempts or
  one if the error is of a kind repetition can't fix. Without this a cloud
  engine re-uploaded and re-charged for the same unusable audio at every
  launch.
- **Speaker attribution across two tracks.** A diarizing engine needs one
  stream, so the tracks are mixed onto a shared clock; the anonymous `A`/`B`
  labels that come back are then mapped to `me`/`them` by asking which source
  track was loud while each utterance was spoken. Per utterance, not per label,
  so a model that merges two similar voices still comes out split. Where the
  tracks genuinely can't settle it, the raw labels are kept rather than
  guessed.
- **An echo filter**, for meetings played through speakers, where the far end
  lands on both tracks and every sentence would otherwise appear twice.

## Summaries

New here entirely. After the transcript: topic, key points, decisions, action
items, open questions.

The backend chain is ordered on purpose — the local `claude` CLI, then the
Anthropic API, then `codex`, then the OpenAI API, then ollama. Subscriptions
before metered keys, because one is already paid for. A spent allowance is not
a failure and is not treated as one: an exhausted CLI says so, and the next
backend takes over. When nothing at all can be reached the session is marked
`summary_status: deferred` rather than dropped, so a meeting summarized on a
plane still gets its summary that evening.

The default model is the expensive one. A summary is the place where a cheap
model quietly costs you a decision nobody will listen to the recording to
recover, and the difference is a few cents a meeting.

## Three surfaces instead of one

quill is a menu bar item. That is not a dependable place for the only control
of a recorder: when the menu bar runs out of room macOS parks the item
off-screen — measured at x = −9406 on a laptop with a notch — and a menu bar
manager can hide it outright. It stays perfectly clickable and completely
invisible, which for a program whose whole job is answering "am I recording?"
is the worst available failure.

So there is also an ordinary window (ordinary on purpose — it sits in the
normal stacking order rather than floating above everything) and a Dock icon
that turns red while recording with the elapsed time as its badge. Pause writes
silence rather than tearing down the capture, so every timestamp after it stays
true.

## Sessions that are folders, named after meetings

quill writes files by timestamp. amanu writes one folder per meeting —
`2026.08.18-1024 клиент АД зум (zoom.us)` — holding the audio, `transcript.md`
and `transcript.json`, `summary.md`, `meta.json` and a per-session log. The
name comes from the calendar when the calendar knows, and from the app
otherwise.

## Odds and ends worth naming

- **Signing in the Makefile.** macOS attributes microphone and system-audio
  grants to the code signature, and SwiftPM only ad-hoc signs — so every
  rebuild looked like a new program, re-prompted, and left another dead entry
  in System Settings.
- **The Info.plist is linked into the binary** (`__TEXT,__info_plist`) so TCC
  can attribute permissions to amanu when it runs as a LaunchAgent with no app
  bundle to carry a plist.
- **The mix is summed by hand.** `AVAssetExportSession` drags in AVFoundation's
  media-library machinery, and macOS answers by asking for Photos, Media &
  Apple Music and the Documents folder — mid-meeting, from a recorder that
  touches none of them.
- **The recording icon is redrawn in colour rather than tinted.**
  `contentTintColor` doesn't override template rendering, so the red icon
  vanished on dark wallpaper.
- **A test suite**, which upstream has none of. 53 tests, most of them
  regression tests for the failures listed above — the absolute level floor in
  speaker attribution, the compressed-track verification, the recovery of an
  interrupted session, the mix keeping its timing across a sample-rate
  mismatch.

## What did not change

The shape. It is still a single Swift binary with no app bundle, still a Core
Audio process tap for system audio with no virtual device and no kernel
extension, still local unless you hand it a cloud token. MIT, as upstream.
