# Speaker names, and finishing what the network interrupted

2026-08-18

## Why

Two complaints, one shared cause.

The mic track carries the far end's voice as well as the user's, because
acoustic echo cancellation is off by default. On the diarizing engine that
doesn't duplicate text — the mix is transcribed once — but it does make speaker
attribution harder than it needs to be, and on the per-track engine it is the
reason `EchoFilter` has to exist at all.

And a transcript says `me` and `them A`. Real names are what make it readable
and forwardable, and the meeting's attendees are already sitting in `meta.json`
from the calendar. But naming needs a language model, and a laptop that recorded
a meeting on a train has no model to ask — so the work has to be able to wait
and be picked up later, which is exactly what a summary already fails to do:
`Summarizer` logs its failure and drops it for ever.

## What changes

### 1. Echo cancellation by default

`mic_voice_processing` defaults to `true`. The stale doc comment in
`MicRecorder` — which already claims this is the default — becomes true rather
than aspirational.

The trade the user accepts: the live voice unit ducks other playback, so music
during a recording gets quieter, and on headphones the unit works for nothing.
`"mic_voice_processing": false` turns it back off. The existing first-second
liveness check still restarts capture raw if the unit delivers zeroed buffers,
so the worst case is today's behaviour rather than a silent track.

### 2. Naming pass

`me` is resolved without a model: `user_name` from config, else the account's
full name, else `me`. The account name is used only when it looks like a
person's — different from the short login, at least two letter-only words, and
not matching device-name shapes (`MacBook`, `iMac`, `'s`, `User`,
`Administrator`). "Samat Galimov" passes; "samat" and "Samat's MacBook" do not.

Every other label goes to a model with the calendar attendees, the meeting
title, the call app and the transcript. It answers with, per label, a name, a
confidence, and a quote that justifies it.

Two filters stand between that answer and the transcript:

- **Confidence.** Only `high` is applied. Anything less leaves the label as
  `them A` — an honest `them A` beats a wrong name.
- **The quote must exist.** The justifying quote is searched for in the
  transcript; if it isn't there, the proposal is dropped whatever confidence it
  claimed. This is cheap and catches the worst failure mode, a confidently
  invented name.

A name is not required to come from the attendee list: people join meetings
they weren't invited to, and being addressed by name out loud is evidence.

Long transcripts are not chunked whole. Name evidence lives at the start
(greetings, introductions) and in vocatives, so an over-long transcript is sent
as its opening, its close, and every segment mentioning an attendee's name.

### 3. `speakers.json`

Written next to the transcript. Per label: the name, its source (`account`,
`config`, `model`, `manual`), the confidence and the quote.

`transcript.json` never changes — it stays the raw recognizer output, and it
stays the completion marker. `transcript.md` is re-rendered from the two files
together; a label with no name prints as itself.

`manual` is never overwritten by a later run. A name typed by a person outranks
the model permanently.

### 4. Deferred post-processing

Order: transcript → names → summary. Names before the summary is the point:
the summary is handed the resolved names in its `context:` array and writes
"Фёдор пришлёт договор" rather than "them пришлёт".

State lives in `meta.json` via `SessionState`, alongside the summary's existing
keys. `speakers_status` mirrors `summary_status` exactly:

- `deferred` — no model could be reached. Retry later.
- `failed: <reason>` — retrying won't help.
- absent — nothing to do.

Which of the two a failure is comes from `LLMError.isTransient`: offline,
connection refused and a spent allowance are transient, while an answer that
came back malformed is not — the model replied, it just replied badly, and
asking again won't change that.

*Changed during implementation.* The design called for a counter, retiring a
step after three bad answers. There is no counter: a non-transient failure
marks the step `failed` on the first occurrence, exactly as `Summarizer`
already does. Two states matching one rule beat two states matching two, and
the case a counter would rescue — a model that answers badly once and well the
next time — is rare enough not to justify a second retry policy sitting beside
the first. Clearing the key by hand offers the session again.

Triggers: daemon start, the end of a transcription, the network coming back
(`NWPathMonitor`), the button, the script.

A summary that already succeeded with `me`/`them` is left alone. Regenerating
it is the user's decision, not a side effect of naming.

### 5. Three ways in

**Window.** A recordings list: date and title, what transcribed it, whether a
summary exists, how many speakers are named. Selecting a session shows the
opening exchange as context, then each speaker with their first and longest
utterance and a field for the name. Buttons: finish processing, re-transcribe,
open folder, delete to Trash (`NSWorkspace.recycle` — these are meetings).

**CLI.** `amanu sessions` prints the same list; `amanu process <dir>` finishes
one session.

**Script.** `Finish processing.command` in each session folder, written when
the recording finishes and back-filled for older folders during a scan. It
resolves its own directory, finds the binary in `~/.local/bin`,
`/opt/homebrew/bin`, `/usr/local/bin` or `PATH`, and hands its directory over.

Because the script passes its own location, moving a session folder anywhere on
the machine keeps it working — which means `amanu process` must accept an
arbitrary path and must not require the folder to live under the recordings
root. The script stays a shim so it can never go stale.

## Boundaries

New files own the new behaviour: `SpeakerNames` (the file format and its
rendering), `SpeakerNamer` (the pass), `SessionInventory` (status from disk),
`PostProcessor` (what to run and when), `RecordingsWindow`.

Consumed rather than copied: `LLMBackend.available()` for model access,
`SessionState` for `meta.json` writes, `Summarizer` unchanged in signature.
`speaker_names.model` is honoured only when set — naming is easier than
summarizing and needn't run on the summary's model.

Existing files change minimally: one default in `Config`, one insertion in
`TranscriptionCoordinator` between the transcript and the summary, one button
at the end of `StatusWindow`'s stack.

## Tests

The owner-name heuristic across real name, login, device name, empty. A
fabricated quote rejected. Confidence below `high` not applied. `manual`
surviving a re-run. `SessionInventory` statuses across file combinations.
`transcript.md` rendered with names known for some labels and not others.
