# quill

A minimal macOS meeting recorder + transcriber. It records your mic and all
system audio as two separate tracks — on a menu-bar click, or on its own when a
call starts — then transcribes both, writes a speaker-tagged transcript, and
summarizes it. On-device by default: nothing leaves the machine unless you opt
into the cloud engine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
make install                      # build, sign, → ~/.local/bin/quill
quill install --launch-at-login   # required for system audio — see Gotchas
```

No sudo: `~/.local/bin` is yours, and `/usr/local/bin` doesn't exist on a
stock Mac anyway. `make install PREFIX=/usr/local` if you'd rather (that one
does need write access).

**Signing isn't cosmetic here.** macOS attributes the microphone and Screen &
System Audio Recording grants to the binary's code signature, and SwiftPM only
ad-hoc signs — meaning the identity *is* the hash of the binary, so every
rebuild looks like a brand-new program, re-prompts for permission, and leaves
another dead `quill` in System Settings. `make` signs with the first real
identity it finds (`make identities` lists them), which gives a stable
designated requirement:

```
designated => identifier "com.digimata.quill" and anchor apple generic and ...
```

No hash in there, so grants survive rebuilds. With no certificate on the
machine it falls back to ad-hoc and still works — you just get the re-prompts.
`make install SIGN_ID="Developer ID Application: ..."` to pick one explicitly.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** via the LaunchAgent (`quill install --launch-at-login`). Running
   `quill` from a terminal records the mic fine, but the system-audio track
   comes out silent — see Gotchas.
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

4. **Or don't touch it at all.** With auto-record on (the default), quill starts
   when a call app opens the microphone and stops when the call ends — see
   [Recording by itself](#recording-by-itself).
5. **Pause** from the menu for the part you'd rather not have on tape. Capture
   keeps running and silence is written, so everything after the pause stays
   aligned to the wall clock.

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
| `mic.m4a` | your side (default input device) |
| `system.m4a` | everything the Mac played — the other side of the call |
| `meta.json` | timestamps, duration, per-track offsets, trigger, stop reason, the app, and the calendar event's title, attendees and link |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `summary.md` | topic, key points, decisions, action items, open questions |
| `transcribe.log` | transcription progress/errors for this session |
| `mixed.m4a` | both tracks on one clock, for a diarizing engine — deleted once the tracks are compressed |
| `transcript.assemblyai.json` | raw API response — only with the assemblyai engine |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model.

While the meeting runs, those two tracks are **uncompressed PCM** in `.caf`,
about a gigabyte an hour between them. Once the transcript exists they're
re-encoded to `.m4a` (about 12× smaller) and the PCM is deleted; `meta.json`
is rewritten to point at the new files first, so an interruption anywhere in
that sequence still leaves a session whose files exist. `compress_tracks:
false` keeps the PCM, `keep_uncompressed: true` keeps both.

The format is not an aesthetic choice — see below.

## Where the controls live

Three surfaces showing one state, because the menu bar can't be relied on
alone:

- **A window.** Small, floating, closable — recording state and elapsed time,
  Start/Stop, Pause/Resume, the auto-record switch with its current reasoning,
  and a button to the recordings folder. Closing it hides it; the Dock icon or
  the menu's **Show quill window** brings it back.
- **A Dock icon**, which turns red while recording and orange while paused,
  with the elapsed time as its badge. Clicking it reopens the window.
- **The menu bar item**, as before.

The window and the Dock icon exist because a status item is not a dependable
place for the only control of a recorder. When the menu bar runs out of room
macOS parks the item off-screen — measured at x = −9406 on a laptop with a
notch — and a menu bar manager can hide it outright. The item stays perfectly
clickable and completely invisible, which for a program whose entire job is
answering "am I recording?" is the worst way it can fail.

`dock_icon: false` returns quill to a menu-bar-only accessory; `window: false`
stops the window opening at launch.

## Recording by itself

Two independent triggers, either of which is enough:

- **A call app opens the microphone** and holds it for `start_delay_seconds`.
  This needs no per-app integration and no calendar — it fires for Zoom, Teams,
  Meet in a browser tab, Slack huddles, Telegram, FaceTime.
- **A calendar event that looks like a call** just started: more than one
  attendee, or a conference link in the location, URL, or notes. Off by default
  because it costs a permission prompt and is only as good as your calendar.

Attribution is by whitelist (`auto_record.apps`), not by "someone opened the
mic". Dictation tools, Voice Memos and a browser tab checking levels all open
the microphone, and every false positive is a recording of whatever was in the
room. A missed meeting costs one click; a false one costs privacy. Set
`"apps": []` to count any app instead.

Stopping is the part that has to be right, because the failure mode is
unbounded. Three rules, any of which ends the session:

- nobody has held the mic for `stop_delay_seconds` **and** the far end has been
  quiet that long;
- **silence on both tracks** for `silence_stop_minutes`, whatever the mic says.
  This is the backstop: an app that never releases the input device would
  otherwise keep a recording alive indefinitely — mygranola, quill's ancestor,
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

Requires macOS 14.4 for per-process microphone attribution. Below that, quill
can't tell your call from its own capture, so auto-record stays off rather than
recording itself in a loop.

## Summaries

After the transcript is written, quill writes `summary.md`: topic, key points,
decisions, action items, open questions. Three backends, tried in order when
`summary.backend` is `auto`:

1. **Anthropic API** — `ANTHROPIC_API_KEY`, or a key in
   `~/.config/anthropic/token`.
2. **The local `claude` CLI** — bills against the subscription already signed in
   on this machine instead of per token. Invoked with an empty MCP config, so it
   doesn't spend a minute starting every server you've configured for a one-shot
   prompt.
3. **ollama** — fully offline, `summary.ollama_model` (default `qwen3:8b`).

Whatever the session knows about the meeting goes in above the transcript —
title, participants, the app it ran in. The participant list earns its place:
given names, the summary says "Anna will send the contract" instead of "them
will send the contract".

A failed summary is logged and dropped; it never costs the transcript. Long
transcripts are summarized in parts and the parts summarized together.

## Transcription

Built in and automatic, with two engines behind one protocol. Jobs run in a
serial queue — you can start a new recording while the last one transcribes.
Unfinished jobs resume on next launch (the filesystem is the queue: a session
with `meta.json` but no `transcript.json` is pending). Failures append to the
session's `transcribe.log` and never block later jobs.

Set `transcription.language` either way. Both engines do better told than
guessing, and the failure mode of a wrong guess is a transcript that reads as
fluent nonsense rather than one that's obviously broken.

### parakeet — local, the default

**Parakeet TDT 0.6B v3** via
[FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port:
25 European languages including Russian, roughly 20 seconds per hour of audio
on Apple Silicon, nothing leaving the machine. Models (~600 MB) download once
on first transcription; `quill doctor` tells you whether they're already cached
so you're never downloading after an important meeting.

Each track is transcribed separately, shifted by its start offset so both share
one clock, and merged by timestamp. The track *is* the speaker — `me` vs
`them`, no speaker model involved.

`transcription.language` is passed as a script hint: it makes the decoder skip
candidate tokens from the wrong alphabet, which is what keeps Russian from
coming back transliterated into Latin.

### assemblyai — cloud, diarizing

Opt-in with `"engine": "assemblyai"`. Better on Russian than parakeet, and it
tells apart multiple people sharing one audio channel — a call with three
others on the far side comes back as three speakers instead of one `them`.

Diarization needs everyone on one stream, so quill first mixes the two tracks
into `mixed.m4a`, laid out on the same shared clock the two-track transcript
uses. That file is uploaded, transcribed, and polled until done. It's derived,
so deleting it is safe — it regenerates.

Speaker labels then come back anonymous (`A`, `B`), and quill maps them onto
`me`/`them` by asking the source tracks: whichever track was loud while an
utterance was spoken is the side that spoke it. That runs per utterance, not
per label, so a model that merges two similar voices into one label still comes
out split correctly. Labels are kept as suffixes (`them A`, `them B`) only
where a side really holds more than one person. If the tracks can't settle it —
one is missing or silent — the raw labels are kept rather than guessed at, and
the log says so.

The full API response is cached as `transcript.assemblyai.json`. A retry after
a crash re-renders from that file instead of re-uploading and re-paying.

**This is the one part of quill that isn't local.** Your meeting audio goes to
AssemblyAI's servers. `quill doctor` says so out loud when the engine is
selected.

The key is read from `~/.config/assemblyai/token` (chmod 600), or
`ASSEMBLYAI_API_KEY`, or `transcription.assemblyai.api_key`:

```sh
mkdir -p ~/.config/assemblyai
printf '%s' YOUR_KEY > ~/.config/assemblyai/token
chmod 600 ~/.config/assemblyai/token
```

To re-transcribe a session with the other engine, delete its
`transcript.json` and restart quill — it'll come back through the queue.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": {
    "enabled": true,
    "engine": "parakeet",
    "language": "ru",
    "assemblyai": { "api_key_path": "~/.config/assemblyai/token" }
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
- `transcription.engine` — `parakeet` (local, default) or `assemblyai` (cloud,
  diarizing).
- `transcription.model` — parakeet only: `v3` (multilingual, default) or `v2`
  (English-only, marginally higher recall on English). `doctor` warns if you
  pair `v2` with a non-English `language` — v2 doesn't fail on other
  languages, it returns English-looking nonsense.
- `transcription.language` — two-letter code, e.g. `ru`. Unset means parakeet
  runs unhinted and assemblyai auto-detects; set it.
- `transcript_echo_filter` — drop mic segments that duplicate overlapping
  system speech at merge time (default on). The text-level guard for sessions
  recorded raw through speakers, where the far end lands on both tracks and
  every sentence appears twice. Per-track engines only — a diarizing engine
  reads one mixed file and can't produce the duplicate. Costs nothing when
  there's no echo; `false` keeps every segment.
- `transcription.assemblyai.api_key_path` / `api_key` — where the key lives, or
  the key itself. `ASSEMBLYAI_API_KEY` wins over both.
- `transcription.assemblyai.speech_model` — override AssemblyAI's default
  model. Unset sends nothing and lets the API pick.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `auto_record.*` — when quill records on its own; see
  [Recording by itself](#recording-by-itself). `apps` is the whitelist of
  bundle-id prefixes that count as a call (defaults to the known conferencing
  apps and browsers; `[]` means any app), `ignore_apps` never counts.
- `dock_icon` — show quill in the Dock and ⌘-Tab (default on). `false` makes
  it a menu-bar-only accessory again.
- `window` — open the status window at launch (default on).
- `compress_tracks` — re-encode the PCM tracks to AAC once the transcript
  exists (default on). `false` leaves every session as PCM, about a gigabyte
  an hour.
- `keep_uncompressed` — keep the PCM alongside the compressed tracks rather
  than deleting it (default off).
- `summary.*` — `enabled`, `backend` (`auto`, `anthropic-api`, `claude-cli`,
  `ollama`, `none`), `language` (unset means the language of the meeting),
  `model`, `ollama_model`, `api_key_path`.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript and summary are written** (or right after
  recording if transcription is disabled). Wire it to whatever comes next:
  filing, indexing, posting.

## CLI

```sh
kill -USR1 $(pgrep -x quill)  # start/stop from a hotkey tool
```

If the menu bar item is nowhere to be seen, it has been pushed off-screen
rather than lost — the window and the Dock icon are unaffected. To confirm:

```sh
osascript -e 'tell application "System Events" to tell process "quill" to get position of menu bar item 1 of menu bar 1'
```

A negative x means the item is parked outside the display.

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models/keys
quill install --launch-at-login
quill install --uninstall
```

`--launch-at-login` points the agent at the binary you ran it from, so install
first, then register.

```sh
make            # build + sign
make install    # also copy to $(PREFIX)/bin
make identities # list signing identities
make verify     # show the installed binary's signature
make uninstall  # remove the binary and the LaunchAgent
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming PCM capture, AAC re-encode once the transcript exists
- **AVMutableComposition** — offset-aware mixdown for the diarizing engine
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **AssemblyAI** — optional cloud transcription with diarization
- **NSStatusItem** — the whole UI

## If quill dies mid-meeting

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
logout, restart, `launchctl kickstart -k`, `quill install --uninstall` — by
closing the tracks cleanly instead of dying mid-file.

The other half is knowing the session was there at all. The transcription queue
only considers folders with a `meta.json`, and that's written on a clean stop
(upstream issue #8).

So a live session now keeps a small `.recording.json` manifest — the owner's
PID, the start time, the track names, the clock offsets. On the next launch,
quill adopts every manifest whose owner process is gone, writes the `meta.json`
the clean-stop path would have written (`"stop_reason": "recovered-after-crash"`),
and lets the session through the normal queue. A manifest with a live owner is
left strictly alone, and a session with no audio in it is skipped rather than
queued empty.

While recording, both tracks are watched for stalls: a `.caf` that stops growing
for 45 seconds notifies you then and there, and the fact is recorded in
`meta.json` as `stalled_tracks` — a one-sided transcript should be explainable
afterwards, not a mystery.

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- **`system.caf` is silent unless quill runs as a LaunchAgent.** Launched from
  a terminal, quill's TCC request is attributed to the terminal rather than to
  quill, so the process tap is created successfully and then delivers nothing
  but zeros — no error, no prompt, a full-length silent file. Under launchd
  quill is its own responsible process, macOS prompts by name, and capture
  works. See `.issues/rca-002-system-tap-silent-outside-launchagent.md`.
- Note that system audio is gated on the **System Audio Recording Only** list
  in System Settings → Privacy & Security, not on Screen Recording. A Screen
  Recording grant does not cover it, and a bare binary can't be added to either
  list by hand — the LaunchAgent is what makes the prompt appear.
- Parakeet v3 covers 25 European languages, not every language. Outside that
  set, use the assemblyai engine.
- Echo confuses speaker attribution on the assemblyai path: if the meeting
  plays through speakers, your mic hears them too. That's what
  `mic_voice_processing` is for.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.
- `spctl` rejects the binary if you ask it to. That's expected: Gatekeeper
  only accepts Developer ID or notarized code, and it never evaluates this
  binary anyway — nothing you built locally carries a quarantine flag.
