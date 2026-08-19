---
title: "Nothing but launching the app recovers an interrupted session"
date: 2026-08-20
status: open
affects: "a session whose recorder was killed, and the CLI that is asked about it"
---

## What happens

A recording that ends by having its process killed leaves a folder with audio,
a `.recording.json` naming the dead owner, and no `meta.json`.
`RecordingSession.recoverInterrupted(root:)` knows exactly what to do with that
and does it well — it synthesises the meta the clean stop would have written,
marks it `"stop_reason": "recovered-after-crash"`, deletes the marker and hands
the session to the queue.

It is called from one place: `AppController.init`. So the recovery happens when
the application is launched, and at no other moment.

Everything else refuses. `amanu sessions` filters on `meta.json` and does not
list the folder. `amanu process` says `doesn't look like a recording — no
meta.json in it`. **Finish processing** works from inventory items, so it cannot
see the folder either. `PostProcessor.sweep` and
`TranscriptionCoordinator.resumePending` both gate on the same file. A person
who has just lost a recording to a kill, and reaches for the command line to ask
what survived, is told nothing survived.

Calling `recoverInterrupted` from `Sessions.run()` and before the `meta.json`
guard in `ProcessSession.run()` would settle it. It is already safe to call with
a recording in progress — it skips a folder whose owning pid is alive.

## The smaller thing next to it

The session folder is created before the manifest is written: `RecordingSession`
makes the directory in `init` and calls `writeManifest()` from `start()`, after
both recorders have started. A kill inside that window leaves a folder that may
hold audio and holds no manifest, and `recoverInterrupted` skips those forever,
because a folder with no manifest is indistinguishable from one nobody was
recording into. Moving the manifest write ahead of the recorders closes it.

## The thing that has not been reproduced

`signal(SIGTERM, SIG_IGN)` after the dispatch source is installed means a main
queue that is not being drained does not make the process slow to die — it makes
it immune, and the symptom is a `SIGTERM` that does nothing.
`.issues/006-the-daemon-does-not-answer-sigterm.md` records the one observation
of exactly that, on 0.4.0 build 161, never repeated, most likely the wrong pid.
If it is ever seen again, the defensive shape is a watchdog armed by the
handler — some seconds after `shutdown()` is asked for, leave anyway — so that a
wedged main queue costs a recording its clean stop rather than costing the
machine its logout.

## Where

`Sources/amanu/RecordingSession.swift` — `recoverInterrupted(root:)`, and the
order of `start()`.
`Sources/amanu/Sessions/SessionCommands.swift` — the two commands that should
recover before answering.
`Sources/amanu/Amanu.swift` — the only caller today, and the signal sources.

The comment above the signal sources still describes the AAC-era hazard, which
the move to LPCM removed; `MicRecorder` still says it creates an AAC file. Both
are worth correcting while in there, since they are the sentences someone will
read before deciding how much a kill costs.
