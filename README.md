# quill

A minimal macOS meeting recorder + transcriber. One menu-bar click records
your mic and all system audio as two separate tracks; when you stop, quill
transcribes both and writes a speaker-tagged transcript. On-device by default —
nothing leaves the machine unless you opt into the cloud engine.

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

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |
| `mixed.m4a` | both tracks mixed on one clock — only with a diarizing engine |
| `transcript.assemblyai.json` | raw API response — only with the assemblyai engine |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

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
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

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
- **AVAudioFile** — streaming AAC encode into CAF
- **AVMutableComposition** — offset-aware mixdown for the diarizing engine
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **AssemblyAI** — optional cloud transcription with diarization
- **NSStatusItem** — the whole UI

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
