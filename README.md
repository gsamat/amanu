# amanu

Meeting recorder for the Mac. Afterwards the recording, the transcript and
the summary are in a folder.

- **Records every meeting automatically.**
- **Transcribes by itself** — AssemblyAI if there's a network and a token,
  parakeet on the machine if not.
- **Names the speakers** — from the calendar and from the transcript itself.
- **Writes the summary by itself** — Anthropic, OpenAI or ollama, whichever
  you've given it.
- **Dock icon and a small window** — status, and the controls for a recording.
- **A list of recordings** — what's done, what's still owed, and the buttons
  to finish it.
- **One folder per meeting** in `~/Recordings` — transcript, summary, and
  optional audio.

On-device by default: nothing leaves the machine unless you hand it a cloud
token.

*Amanuensis* — the person who writes down what is said, from Latin *servus a
manu*, "the slave of the hand". The job is old; only the writing-down is new.

A fork of [digimata/quill](https://github.com/digimata/quill), rewritten well
past the point of a patch — [what changed and why](FORK.md).

## Install

Download the disk image from
[the latest release](https://github.com/gsamat/amanu/releases/latest), drag
`Amanu.app` to Applications, and open it. Apple Silicon, macOS 15 or later; the
image is signed with a Developer ID certificate and carries a stapled
notarization ticket, so Gatekeeper opens it without argument.

From a checkout instead:

```sh
cd amanu
make app                          # build, sign → .build/Amanu.app
cp -R .build/Amanu.app /Applications/
open /Applications/Amanu.app      # first run opens Setup
```

amanu is an ordinary macOS application: a Dock icon, a menu bar item, and a
small status window. Closing the window doesn't stop it — that's the point of
a recorder — and **Start at login** in Setup registers it the way every other
app does, through Login Items in System Settings.

The first launch points `~/.local/bin/amanu` at the executable inside the
bundle, so scripts and agents keep working and reach the same signed program
the app runs. A binary already sitting there is moved aside with the date,
never deleted.

`make` on its own builds and signs the app; `make run-app` launches it the way
Finder would. There is no daemon.

It updates itself. Sparkle checks
[the feed](https://samat.me/amanu/appcast.xml) once a day, verifies Apple's
signature and an EdDSA signature of its own before installing anything, and
**Check for updates…** in either menu asks on demand. A check that lands during
a recording is skipped, and an update that arrives anyway waits for the
recording to end rather than quitting in the middle of a meeting.

**Signing isn't cosmetic here.** macOS attributes the microphone and Screen &
System Audio Recording grants to the binary's code signature, and SwiftPM only
ad-hoc signs — meaning the identity *is* the hash of the binary, so every
rebuild looks like a brand-new program, re-prompts for permission, and leaves
another dead `amanu` in System Settings. `make` signs with the first real
identity it finds (`make identities` lists them), which gives a stable
designated requirement:

```
designated => identifier "me.samat.amanu" and anchor apple generic and ...
```

No hash in there, so grants survive rebuilds. With no certificate on the
machine it falls back to ad-hoc and still works — you just get the re-prompts.
`make SIGN_ID="Developer ID Application: ..."` to pick one explicitly.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

**Why an application and not a daemon.** System audio is captured by whichever
process macOS holds *responsible* for the request. A binary started from a
terminal is attributed to the terminal, gets no prompt, and records a
full-length silent file — the failure documented in
`.issues/rca-002-system-tap-silent-outside-launchagent.md`, which is why amanu
shipped with a LaunchAgent for a year. A signed application bundle is its own
responsible process, which `spike/tcc-bundle` measures directly by playing a
tone into its own tap and counting the samples that come back.

## How to use

1. **Open Amanu.** On the first run, Setup registers it at login before it
   asks for access, requests microphone/system-audio/calendar permissions, and
   lets you choose transcription, summaries, and whether audio is kept. It also
   detects working Claude Code and Codex CLIs, including Codex bundled with the
   ChatGPT desktop app. Reopen it later from either menu or with `amanu setup`.
2. **Click the feather in the menu bar → Start recording.** While recording,
   the icon turns red with a running elapsed counter, and macOS shows the
   purple recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.
4. **Or don't touch it at all.** With auto-record on (the default), amanu
   starts when a call app opens the microphone and stops when the call ends —
   see [Recording by itself](#recording-by-itself).
5. **Pause** from the menu for the part you'd rather not have on tape. Capture
   keeps running and silence is written, so everything after the pause stays
   aligned to the wall clock.
6. **Look at what came out** in **Manage recordings…** — every session with
   its transcript, names and summary, and what is still missing from any of
   them.

Each session lands in `~/Recordings/`, named so a folder listing is readable
on its own:

```
2026.08.17-1400 Integration sync (zoom.us)
2026.08.17-1630 Telegram
2026.08.17-2039
```

Timestamp first — the transcription queue orders pending sessions by name and
relies on that being chronological — then the calendar's title for the meeting,
then the app that was holding the microphone, which is the one piece of context
available even with the calendar switched off. Anything unknown is simply left
out; a manual recording with neither still gets a valid timestamped folder.

Inside:

| File | Contents |
|---|---|
| `audio.m4a` | compact stereo archive when **Keep audio** is on: your mic left, the other side right |
| `meta.json` | timestamps, duration, per-track offsets, trigger, stop reason, the app, and the calendar event's title, attendees and link |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading, with names where they're known |
| `speakers.json` | who each speaker label is, where the name came from, and the line that proves it |
| `summary.md` | topic, key points, decisions, action items, open questions |
| `transcribe.log` | transcription progress/errors for this session |
| `mixed.m4a` | temporary mix for a diarizing engine; removed after transcription |
| `transcript.assemblyai.json` | raw API response — only with the assemblyai engine |

Two tracks while recording on purpose: speech models do better on clean
single-source audio, and mic-vs-system is free two-party diarization — `me` vs
`them` with no speaker-identification model. A retained `audio.m4a` preserves
that separation in its left and right channels.

While the meeting runs, those two tracks are **uncompressed PCM** in `.caf`,
about a gigabyte an hour between them. Once `transcript.json` has been written,
the audio is deleted by default; naming and summaries read the transcript and
do not need it. A failed transcription always keeps the recording so it can be
tried again. Turn on `keep_audio` to retain successful recordings; the two PCM
tracks are then aligned and encoded as one stereo AAC `audio.m4a`, with the
microphone on the left and system audio on the right.

The format is not an aesthetic choice — see [If amanu dies
mid-meeting](#if-amanu-dies-mid-meeting).

## Where the controls live

Three surfaces showing one state, because the menu bar can't be relied on
alone:

- **A window.** Small and ordinary — it sits in the normal stacking order and
  goes behind whatever you bring forward. Recording state and elapsed time,
  Start/Stop, Pause/Resume, the auto-record switch with its current reasoning,
  and buttons to the recordings folder and to the list of recordings. Closing
  it hides it; the Dock icon or the menu's **Show Amanu window** brings it
  back.
- **A Dock icon**, which turns red while recording and orange while paused,
  with the elapsed time as its badge. Clicking it opens the window, and
  clicking it again — with amanu already in front — puts it away.
- **The menu bar item**, as before: the same state and the same controls,
  plus **Manage recordings…**, **Settings…**, and **Setup…**. Settings and Setup
  are also in the app menu.

The window and the Dock icon exist because a status item is not a dependable
place for the only control of a recorder. When the menu bar runs out of room
macOS parks the item off-screen — measured at x = −9406 on a laptop with a
notch — and a menu bar manager can hide it outright. The item stays perfectly
clickable and completely invisible, which for a program whose entire job is
answering "am I recording?" is the worst way it can fail.

`dock_icon: false` returns amanu to a menu-bar-only accessory; `window: false`
stops the window opening at launch.

## What's recorded, and what's still owed on it

**Manage recordings…** — from the menu bar item, from the window, or as
`amanu sessions` in a terminal — is the other half: not "am I recording" but
what has been recorded. Every session under `~/Recordings`, newest first, with
a column each for the transcript, the names and the summary, and the state of
each: `done`, `pending`, `deferred` (nothing could be reached, it comes back
on its own), `failed` (a retry won't help), or `off`.

The list is read from the disk each time and keeps no index of its own. The
recordings folder is somewhere you go with the Finder — you delete things from
it and move folders out of it — and a cache of what's in there would spend its
life being wrong. A few hundred folders scan in milliseconds.

Selecting a session shows how the meeting opened and, per speaker, how many
turns they took, their first line and their longest one, with a field for the
name. Both lines are there because they answer different questions: the first
is where somebody gets greeted by name, and the longest is what identifies a
person by what they were talking about when nobody said any names at all. A
name typed in that field is marked `manual`, and no later run overwrites it.

Four buttons, on the selected session:

- **Finish processing** — do whatever is still outstanding on a session that
  never finished: the names, the summary. The same work as `amanu process` and
  as `amanu process <folder>` from a terminal — which works wherever the folder
  has been moved to. A session that has settled into `audio.m4a` with no
  transcript is **Re-transcribe**'s job, not this one.
- **Re-transcribe** — throw the transcript, its names and the summary away and
  make them again from the audio, which is kept either way. It asks first, and
  says that. `amanu process --again <folder>` is the same thing from a
  terminal, and waits for the transcript instead of handing it to a queue.
- **Open folder** — in the Finder; double-clicking a row does the same.
- **Delete** — to the Trash, never `rm`. These are meetings: a mistaken delete
  costs somebody's only record of a conversation, and the Trash is what makes
  that recoverable.

## Recording by itself

Two independent triggers, either of which is enough:

- **A call app opens the microphone** and holds it for `start_delay_seconds`.
  This needs no per-app integration and no calendar — it fires for Zoom, Teams,
  Meet in a browser tab, Slack huddles, Telegram, FaceTime.
- **A calendar event that looks like a call** just started: more than one
  attendee, or a conference link in the location, URL, or notes. Off by default
  because it costs a permission prompt and is only as good as your calendar.

Who is on the microphone is read per process, not per device — otherwise
amanu's own capture looks like a meeting in progress and keeps itself alive in
a loop. And it counts only apps on a whitelist (`auto_record.apps`), rather
than anything that opens the mic: dictation tools, Voice Memos and a browser
tab checking levels all open it, and every false positive is a recording of
whatever was in the room. A missed meeting costs one click; a false one costs
privacy. Set `"apps": []` to count any app instead.

Stopping is the part that has to be right, because the failure mode is
unbounded. Three rules, any of which ends the session:

- nobody has held the mic for `stop_delay_seconds` **and** the far end has been
  quiet that long;
- **silence on both tracks** for `silence_stop_minutes`, whatever the mic says.
  This is the backstop: an app that never releases the input device would
  otherwise keep a recording alive indefinitely — mygranola, amanu's ancestor,
  produced three back-to-back recordings totalling about fifteen hours in one
  night this way;
- `max_duration_minutes`, the hard ceiling, which applies to manual recordings
  too.

An automatic recording shorter than `min_duration_seconds` is deleted rather
than transcribed — that's what a mic opening for a few seconds is. Manual
recordings are never auto-stopped and never discarded: if you pressed the
button, only you decide.

The menu shows what the loop is currently thinking ("waiting", "Zoom on the mic
for 7s", "quiet for 40s"), which is the difference between debugging a missed
recording and guessing at it. The checkbox next to it turns the whole thing off
immediately, without touching the config file.

## Whose audio is on the far-end track

By default amanu taps **only the call app's output**, not everything the Mac
plays. The app is whichever call app holds the microphone when recording
starts, and the tap follows its whole bundle-id family — Chrome renders call
audio in a helper process, Zoom and Teams each ship several — plus any other
call app that joins later, because clicking a Zoom link during a browser call
is an ordinary thing to do. On macOS 26 the tap also survives those processes
restarting.

This matters twice over. The transcript stops collecting music, notification
dings and whatever video you opened afterwards. And "the far end has gone
quiet" starts meaning *the call ended* rather than *nothing at all is playing
on this machine* — with a global tap, a video opened after a meeting kept a
recording alive for ten extra minutes (2026.08.18).

When the call app can't be identified — a manual recording with nothing on the
mic — the tap falls back to everything. Recording too much is a small wrong;
recording nothing is the wrong that loses the meeting. For the same reason a
scoped tap that has been silent for five minutes while you were talking says so
in a notification: a tap pointed at the wrong process delivers silence with no
error at all.

`system_audio: "all"` restores the old global behaviour.

## Transcription

Built in and automatic, with two engines behind one protocol. Which one runs
is `transcription.engine`, `auto` by default: cloud when a key and a network
are both there, local otherwise.

Jobs run in a serial queue, so a new recording can start while the last one is
still being transcribed, and unfinished jobs resume at the next launch — the
filesystem *is* the queue, a session with a `meta.json` and no
`transcript.json` is pending. Failures append to that session's
`transcribe.log` and never block later jobs.

A session that keeps failing is retired rather than retried for ever: three
attempts, or one if the error is of a kind repetition cannot fix, such as
audio with no speech in it. Retiring writes `transcription_failed` into
`meta.json`, keeps the audio and compresses it; delete that field to offer the
session to the queue again. Without this a cloud engine re-uploaded, and
re-charged for, the same unusable recording at every launch.

Set `transcription.language` either way. Both engines do better told than
guessing, and the failure mode of a wrong guess is a transcript that reads as
fluent nonsense rather than one that's obviously broken.

### parakeet — local

**Parakeet TDT 0.6B v3** via
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port:
25 European languages including Russian, roughly 20 seconds per hour of audio
on Apple Silicon, nothing leaving the machine. Models (~600 MB) download once
on first transcription; `amanu doctor` tells you whether they're already cached
so you're never downloading after an important meeting.

Each track is transcribed separately, shifted by its start offset so both share
one clock, and merged by timestamp. The track *is* the speaker — `me` vs
`them`, no speaker model involved.

`transcription.language` is passed as a script hint: it makes the decoder skip
candidate tokens from the wrong alphabet, which is what keeps Russian from
coming back transliterated into Latin.

### assemblyai — cloud, diarizing

What `auto` uses when a key is present and the network answers; `"engine":
"assemblyai"` insists on it. Better on Russian than parakeet, and it tells
apart multiple people sharing one audio channel — a call with three others on
the far side comes back as three speakers instead of one `them`.

Diarization needs everyone on one stream, so amanu first mixes the two tracks
into `mixed.m4a`, laid out on the same shared clock the two-track transcript
uses. That file is uploaded, transcribed, and polled until done. It's derived,
so deleting it is safe — it regenerates.

Speaker labels then come back anonymous (`A`, `B`), and amanu maps them onto
`me`/`them` by asking the source tracks: whichever track was loud while an
utterance was spoken is the side that spoke it. That runs per utterance, not
per label, so a model that merges two similar voices into one label still comes
out split correctly. Labels are kept as suffixes (`them A`, `them B`) only
where a side really holds more than one person. If the tracks can't settle it —
one is missing or silent — the raw labels are kept rather than guessed at, and
the log says so.

The full API response is cached as `transcript.assemblyai.json`. A retry after
a crash re-renders from that file instead of re-uploading and re-paying.

**This is the one part of amanu that isn't local.** Your meeting audio goes to
AssemblyAI's servers. `amanu doctor` says so out loud when the engine is
selected.

The key is read from `~/.config/amanu/keys/assemblyai` (chmod 600) — amanu's
own drawer, mode 0700, so no other tool that keeps a key on this machine can
overwrite it. A key already sitting in the shared `~/.config/assemblyai/token`
is read as a fallback, so nobody has to paste theirs twice. Or
`ASSEMBLYAI_API_KEY`, or `transcription.assemblyai.api_key`:

```sh
mkdir -p ~/.config/amanu/keys
printf '%s' YOUR_KEY > ~/.config/amanu/keys/assemblyai
chmod 600 ~/.config/amanu/keys/assemblyai
```

To transcribe a session again — with the other engine, or because the first
result was poor — use **Re-transcribe** in the recordings list, or delete its
`transcript.json` by hand and restart amanu; either way it comes back through
the queue.

### live — while the meeting is still going

Off by default, and separate from everything above: `live_transcription.enabled`
turns on a running transcript in the status window while a meeting is being
recorded. It is a **preview, not a transcript**. The text is held in memory,
never written into the session folder, and never used as a fallback — the
canonical `transcript.json` is still produced by the pass after the recording
stops, by whichever engine `transcription.engine` chose.

It needs a second local model: NVIDIA's streaming multilingual ASR, another
~600 MB, again via FluidAudio's Core ML port. Nothing leaves the Mac. The
download is explicit — Setup or Settings asks for it, and a recording never
starts one on its own, because a 600 MB download beginning as a meeting begins
is the wrong thing to do to a person's laptop and their bandwidth.

Mic and system audio stream through the model as two independent decoders
sharing one loaded bundle, so the live text is labelled `You` and `Them`
without any diarization. The checkbox works mid-recording: turning it on
starts from that instant rather than catching up from the audio already on
disk, turning it off freezes what is on screen, and turning it on again draws
a *live transcript resumed* line. If the machine cannot keep up the live
transcript stops and says so — the recording and the final transcript are
unaffected, which is the point of keeping the preview disposable.

## Speaker names

A transcript comes out of the recognizer saying `me` and `them A`. Before the
summary is written, amanu tries to put real people to those labels, using the
calendar's attendee list and the meeting itself — people say each other's
names out loud, and that is the evidence.

You are resolved without asking anyone: `user_name`, else the account's full
name, else `me`. The account name is only used when it reads as a person's —
"Samat Galimov" yes, "samat" and "Samat's MacBook" no.

The rest go to a model, and two rules stand between its answer and the file:

1. **Only high confidence is applied.** Reasoning from who was invited rather
   than from what was said doesn't qualify. A label nobody could identify
   stays `them A`, which is honest; a wrong name is a transcript that lies.
2. **The justifying quote has to exist.** The model must cite the line its
   answer came from, and that line is checked against the transcript. A model
   that invents a name usually invents its source too.

Names live in `speakers.json`, never in `transcript.json` — the canonical
transcript keeps the recognizer's own labels for ever. `transcript.md` is
rendered from both, so naming is re-runnable and reversible.

A label the model wouldn't touch is not a dead end: **Manage recordings…**
shows each speaker's first and longest line with a field for the name, and a
name typed there is marked `manual` — see [What's recorded, and what's still
owed on it](#whats-recorded-and-whats-still-owed-on-it).

## Summaries

After the transcript is written, amanu writes `summary.md`: topic, key points,
decisions, action items, open questions. With `summary.backend` on `auto` it
walks this chain, using the first that answers:

1. **The local `claude` CLI** — bills against the subscription already signed
   in on this machine rather than per token. Invoked with an empty MCP config,
   so it doesn't spend a minute starting every server you've configured for a
   one-shot prompt.
2. **The Anthropic API** — `ANTHROPIC_API_KEY`, or a key in
   `~/.config/amanu/keys/anthropic` (or the shared `~/.config/anthropic/token`).
3. **The `codex` CLI**, then **the OpenAI API** — same idea on the other side.
4. **ollama** — fully offline, `summary.ollama_model` (default `qwen3:8b`).

Subscriptions before metered keys, and a spent allowance is not an error: when
a CLI reports it is out, the log says so plainly and the next backend takes
over.

The default model is the strong one (`claude-opus-5`, `summary.model`). A
summary is where a cheap model quietly costs you something — a decision missed
in a meeting nobody will listen to again — and the difference between tiers is
a few cents per meeting.

Whatever the session knows about the meeting goes in above the transcript —
title, participants, the app it ran in. The participant list earns its place:
given names, the summary says "Anna will send the contract" instead of "them
will send the contract".

Long transcripts are summarized in parts and the parts summarized together. A
failed summary never costs the transcript, and it isn't simply dropped either:
when nothing could be reached at all (no network, every allowance spent), the
session is marked `summary_status: deferred` in `meta.json` so a later run can
finish the job. A meeting recorded on a plane still gets its summary that
evening. A backend that answered badly is marked `failed` instead, and is not
retried.

### When there's no network

Naming and summarizing both need a model, which a laptop on a train hasn't
got. Neither fails: the session is marked `deferred` and picked up later — at
the next launch, when the network comes back, from **Finish processing** in
the recordings list, or from `amanu process <folder>` in a terminal. That
command takes the folder's location, so a session moved out of `~/Recordings`
still finishes.

An answer that came back malformed is marked `failed` instead and not retried;
delete the key from `meta.json` to offer it again.

## Settings

**⌘,** — from the menu bar item or the app menu. Every setting amanu has, with
a line saying what it does and its default showing as the placeholder, so you
can see what a value would be without setting it. Settings that are only read
at startup say so under the control instead of pretending to take effect.

The window writes `~/.config/amanu/config.json` and writes as little as it can:
a control put back to its default **clears** the key rather than storing
today's default. That keeps the file readable as a list of what you changed,
and it means a default that improves in a later version still reaches you
instead of being frozen the first time you opened the window. An emptied field
means "unset", not "empty".

Keys the running version doesn't read — a typo, or a setting from an older
build — are listed at the bottom of the window rather than silently ignored.
That failure otherwise looks exactly like a setting being disobeyed.

Everything below is the same thing in a text editor; nothing needs the window.

## Config

Optional, at `~/.config/amanu/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "keep_audio": false,
  "transcription": {
    "enabled": true,
    "engine": "auto",
    "language": "ru",
    "assemblyai": { "api_key_path": "~/.config/amanu/keys/assemblyai" }
  },
  "auto_record": {
    "enabled": true,
    "mic_activity": true,
    "calendar": false,
    "start_delay_seconds": 12,
    "stop_delay_seconds": 90,
    "min_duration_seconds": 45,
    "silence_stop_minutes": 10,
    "max_duration_minutes": 300,
    "apps": ["us.zoom", "com.google.Chrome"],
    "ignore_apps": []
  },
  "summary": {
    "enabled": true,
    "backend": "auto",
    "language": "ru"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `transcription.engine` — `auto` (default), `parakeet` (always local) or
  `assemblyai` (always cloud). `auto` picks assemblyai when there's a key and
  the API answers, parakeet otherwise, and it asks at the moment there's a
  session to transcribe rather than at launch.
- `transcription.model` — parakeet only: `v3` (multilingual, default) or `v2`
  (English-only, marginally higher recall on English). `doctor` warns if you
  pair `v2` with a non-English `language` — v2 doesn't fail on other
  languages, it returns English-looking nonsense.
- `transcription.language` — two-letter code, e.g. `ru`. Unset means parakeet
  runs unhinted and assemblyai auto-detects; set it.
- `transcription.assemblyai.api_key_path` / `api_key` — where the key lives, or
  the key itself. `ASSEMBLYAI_API_KEY` wins over both.
- `transcription.assemblyai.speech_model` — override AssemblyAI's default
  model. Unset sends nothing and lets the API pick.
- `live_transcription.enabled` — the running preview in the status window
  while a meeting records (default off). Needs a second local model, which
  Setup downloads on request and a recording never fetches on its own. The
  live text is never saved and never becomes the transcript.
- `transcript_echo_filter` — drop mic segments that duplicate overlapping
  system speech at merge time (default on). The text-level guard for sessions
  recorded raw through speakers, where the far end lands on both tracks and
  every sentence appears twice. Per-track engines only — a diarizing engine
  reads one mixed file and can't produce the duplicate. Costs nothing when
  there's no echo; `false` keeps every segment.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default on).
  A meeting held through the speakers otherwise lands on both tracks, and
  everything downstream has to work around a mic track that isn't only yours.
  The trade: while the voice unit is live, macOS ducks other playback slightly
  (`.min` ducking is configured, but it can't be zeroed), and on headphones it
  cancels an echo that was never there. `false` records raw.
- `user_name` — what to call you instead of "me" in a named transcript. Unset
  falls back to the account's full name, and to "me" when that isn't a
  person's name (a login, "Samat's MacBook", "User").
- `speaker_names.*` — `enabled` (default on), `backend` (same chain as
  summaries), `model` (Anthropic model for this pass; unset uses the
  summary's).
- `auto_record.*` — when amanu records on its own; see
  [Recording by itself](#recording-by-itself). `apps` is the whitelist of
  bundle-id prefixes that count as a call (defaults to the known conferencing
  apps and browsers; `[]` means any app), `ignore_apps` never counts.
- `system_audio` — `app` (default) taps only the call app's output, `all`
  taps everything the Mac plays.
- `calendar` — read the calendar to name sessions after the meeting (default
  on; costs a one-time permission prompt). Independent of
  `auto_record.calendar`, which is about *starting* a recording from an event.
- `dock_icon` — show amanu in the Dock and ⌘-Tab (default on). `false` makes
  it a menu-bar-only accessory again.
- `window` — open the status window at launch (default on).
- `keep_audio` — keep audio after a successful transcript (default off). Audio
  is always kept when transcription fails. Turning this on is what makes
  **Re-transcribe** available for completed sessions. Retained audio is one
  compact stereo `audio.m4a`: microphone on the left, system audio on the
  right.
- `summary.*` — `enabled`, `backend` (`auto`, `claude-cli`, `anthropic-api`,
  `codex-cli`, `openai-api`, `ollama`, or `none` to skip summarizing without
  turning off the rest), `language` (unset means the language of the meeting),
  `model` (Anthropic, API path only — a CLI uses whatever model it is set to),
  `openai_model`, `ollama_model`, `api_key_path` and `openai_api_key_path`
  (where the two keys live; `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` win over
  both).
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript and summary are written** (or right after
  recording if transcription is disabled). Wire it to whatever comes next:
  filing, indexing, posting.

## CLI

```sh
amanu                        # run the menu-bar daemon (^C to quit)
amanu run --out <dir>        # custom recordings root (default ~/Recordings)
amanu setup                  # reopen first-run setup in the running daemon
amanu record start|stop|toggle  # record on purpose, in the running daemon
amanu doctor                 # check permissions, recordings folder, models/keys
amanu sessions               # what's recorded and what's still owed on it
amanu sessions --pending     # only the sessions with work outstanding
amanu process <folder>       # finish one session: a missing transcript, names, summary
amanu process --again <dir>  # transcribe it again, from the archived audio
amanu install --launch-at-login
amanu install --uninstall
```

`amanu record` never records anything itself: it rings the running daemon and
exits. That is not politeness, it's the only thing that works — a recorder
started from a terminal is attributed to the terminal, and its system-audio
track is digital silence (below). With nothing running, the command says so
instead of quietly becoming a second, deaf recorder.

`amanu install --launch-at-login` registers the bundle with Login Items — the
same thing the switch in Setup does. `amanu process` takes a path rather than a
session name,
because a session is complete in its own folder — move it out of
`~/Recordings` and it still finishes.

```sh
make            # build and sign Amanu.app
make run-app    # and launch it through LaunchServices
make icon       # redraw Resources/Amanu.icns from the feather
make identities # list signing identities
make verify     # show the built app's signature
```

Start and stop from a hotkey tool by signal, without a window in the way:

```sh
kill -USR1 $(pgrep -x amanu)
```

If the menu bar item is nowhere to be seen, it has been pushed off-screen
rather than lost — the window and the Dock icon are unaffected. To confirm:

```sh
osascript -e 'tell application "System Events" to tell process "amanu" to get position of menu bar item 1 of menu bar 1'
```

A negative x means the item is parked outside the display.

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`) — system audio
  capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming PCM capture, AAC re-encode once the transcript
  exists
- **AVAudioConverter** — offset-aware mixdown for the diarizing engine, summed
  by hand rather than exported (`AVAssetExportSession` makes macOS ask for the
  photo library)
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **AssemblyAI** — optional cloud transcription with diarization
- **AppKit** — the whole UI by hand: a status item, the Dock icon, and four
  plain windows (status, recordings, settings, setup). No SwiftUI

## If amanu dies mid-meeting

**A CAF full of AAC does not survive a crash, whatever the format's reputation
says.** AAC is variable-bitrate, so the file is undecodable without its packet
table — and that's written when the file is closed. Kill the process
mid-meeting and every byte on disk is unreadable:

```
$ ffmpeg -i system.caf
Missing packet table. It is required when block size or frame size are variable.
$ afinfo system.caf | grep duration
estimated duration: 0.000000 sec
```

That was measured here on 2026.08.17, not reasoned about: 99 KB of audio
written, zero seconds recoverable. So recording writes **linear PCM**, which
has no packet table and no finalization step — whatever reached the disk
decodes, and the same `kill -9` now yields a playable file with the meeting on
it. Compression happens afterwards, when the transcript already exists.

SIGTERM is handled rather than ignored, which covers the ordinary cases —
logout, restart, quitting the app — by closing the tracks cleanly instead of
dying mid-file.

The other half is knowing the session was there at all. The transcription queue
only considers folders with a `meta.json`, and that's written on a clean stop
(upstream issue #8).

So a live session keeps a small `.recording.json` manifest — the owner's
PID, the start time, the track names, the clock offsets. On the next launch,
amanu adopts every manifest whose owner process is gone, writes the `meta.json`
the clean-stop path would have written (`"stop_reason": "recovered-after-crash"`),
and lets the session through the normal queue. A manifest with a live owner is
left strictly alone, and a session with no audio in it is skipped rather than
queued empty.

While recording, both tracks are watched for stalls: a `.caf` that stops growing
for 45 seconds notifies you then and there, and the fact is recorded in
`meta.json` as `stalled_tracks` — a one-sided transcript should be explainable
afterwards, not a mystery.

## Gotchas

- With `system_audio: "all"` the tap records *everything* the Mac plays —
  notification dings, music, all of it. The default (`app`) records only the
  call app.
- **`system.caf` is silent if you run the binary instead of the app.** Launched
  from a terminal, the TCC request is attributed to the terminal rather than to
  amanu, so the process tap is created successfully and then delivers nothing
  but zeros — no error, no prompt, a full-length silent file. `Amanu.app` is its
  own responsible process, macOS prompts by name, and capture works. See
  `.issues/rca-002-system-tap-silent-outside-launchagent.md` for the failure and
  `spike/tcc-bundle` for the measurement that ended it.
- System audio is gated on the **System Audio Recording Only** list in System
  Settings → Privacy & Security, not on Screen Recording. A Screen Recording
  grant does not cover it.
- Parakeet v3 covers 25 European languages, not every language. Outside that
  set, use the assemblyai engine.
- Echo confuses speaker attribution on the assemblyai path: if the meeting
  plays through speakers, your mic hears them too. That's what
  `mic_voice_processing` is for.
- `spctl` rejects a locally built app if you ask it to. That's expected until
  the release is notarized; Gatekeeper never evaluates it anyway, because
  nothing you built yourself carries a quarantine flag.
