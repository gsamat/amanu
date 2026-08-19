---
title: "A recording in progress is invisible from everywhere anyone looks before quitting amanu"
date: 2026-08-19
status: open
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
