---
title: "A recording in progress is invisible from everywhere anyone looks before quitting amanu"
date: 2026-08-19
status: done
affects: "anyone testing a build on the machine that also records the meetings"
---

## What happens

Replacing or restarting amanu is a normal step — `make app`, copy into
`/Applications`, quit, relaunch — and `CLAUDE.md` spells it out. Nothing in
that sequence says whether a meeting is being recorded at that moment.

The places someone looks before quitting are all silent about it. `git status`
knows nothing. `/Applications` knows nothing. The build output knows nothing.
The menu bar item shows it, and the status window shows it, but both are on a
screen the person doing the work is usually not looking at — and neither is
where the decision to quit is taken. The one authoritative answer is a command
nobody is prompted to run:

```sh
amanu sessions | head -3     # a session dated within the last minutes is live
```

## What it costs

Measured on 19 August 2026, during the verification of the shell-launch fix.
A Telegram call was being recorded. The app was quit and relaunched several
times over three minutes to test `amanu setup` and `amanu run --out`.

The parts amanu controls behaved well. The interrupted session was written out
whole, transcribed, and carries `"stop_reason": "app-quit"` in `meta.json` —
44 seconds, saved rather than lost, and honest about why it ended. Auto-record
picked the call up again on the next launch as a new session.

The gap between those sessions is what cannot be recovered: roughly three
minutes of the conversation, some of it never recorded because no copy was
running, some of it recorded into the throwaway `--out` directory the test used
and deleted afterwards. The person on the call was not asked and did not know.

## Why a warning in the docs is not the whole answer

The instruction "check whether a recording is running" is only obeyed by
someone who already suspects there might be one. The failure is specifically
that nothing raises the suspicion. Two shapes would:

- `amanu doctor` — and any command that is about to disturb the app — could say
  "a recording has been running for 4 minutes" from the same state the status
  window reads.
- Quitting could say it out loud. The app already refuses to disturb a
  recording for the setup form's sake (`SetupForm.isRecording`, handed the live
  session in `Amanu.swift`); the same fact is available to an
  `applicationShouldTerminate` the app does not implement, so a quit goes
  through in silence.

Neither is written. This entry exists so the next person testing on the machine
that also records the meetings finds out from here rather than from someone
whose call went missing.

## Where

`Sources/amanu/Sessions/SessionInventory.swift` — what `amanu sessions` reads,
and the same state a warning would come from.
`Sources/amanu/Amanu.swift` — owns the live session and the quit path.
`CLAUDE.md` — "Quit the running app before replacing `/Applications/Amanu.app`"
is the instruction that leads here, and says nothing about looking first.

## Correction, and the answer that does exist

Measured on 0.4.2 build 197, a day after the rest of this note: `amanu sessions`
does not list a recording in progress **at all**. `SessionInventory` filters on
`meta.json`, which is written when the recording stops — so the command answers
"nothing is running" in exactly the case where something is. Everything below
was written believing it showed a `pending` row. It does not, and the mistake
made this note more dangerous than the thing it described.

There is an honest answer on disk, and it was there all along. A session being
recorded holds `.recording.json`, with the owning pid and the moment it started,
written at the start and removed at the end:

```sh
ls ~/Recordings/*/.recording.json
```

Nothing printed means nothing is recording. That is the check to put in front of
anything that quits the application, and `docs/testing/live-pass.md` now opens
with it.

## What the earlier note said about `amanu sessions`

Measured the same evening, an hour later. A session still being recorded
appears in `amanu sessions` as an ordinary row — its elapsed time and
`transcript: pending` — which is indistinguishable from one that stopped a
minute ago and has not been transcribed yet. So the one command that looks
authoritative, and that this note was about to recommend, does not in fact
separate "recording now" from "recently finished".

What did answer honestly was the status window: a running transcript and a
live **Pause** button. That is a window, not something a script can consult,
which is the whole difficulty restated.

Whatever fixes this has to make the answer available where the decision is
made — a line in `amanu doctor`, an exit status, anything a person about to
type `rm -rf /Applications/Amanu.app` would see without having gone looking.

## What was done

Fixed on 20 August 2026, in both the shapes this note asked for.

`amanu doctor` now answers first, from `.recording.json` — the marker the
correction above identified as the honest one. `RecordingSession.inProgress(root:)`
reads it, using the `kill(pid, 0)` liveness test `recoverInterrupted` already
uses and carrying the same caveat about recycled pids, which here errs toward a
false warning rather than a missed one. The check is `.warn`, never `.fail`,
because `allOK` drives `ExitCode(1)` at startup and a meeting in progress must
not stop amanu from launching. A crashed session that has not been recovered
gets its own line rather than being counted as live or passed over in silence.
`amanu setup` prints the same line, from the same check, before it does anything
else.

Quitting now asks. `QuitGate` — shaped after `UpdateGate`, which was already the
project's example of a "do not disturb a recording" rule kept apart from its
UI — turns ⌘Q into a question carrying how long the recording has been going,
and the alert says the part that makes the answer safe: the session is saved
either way, and nothing is recorded until amanu runs again. `AppController` grew
a named `isRecording` that the settings form, the setup form and the update gate
now share instead of four separate tests for a nil session.

Eleven tests. The modal itself is a manual step, C10 in
`docs/testing/live-pass.md`, whose opening check now leads with `amanu doctor`.
