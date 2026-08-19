---
title: "The CLI and the running app can transcribe the same session twice"
date: 2026-08-19
status: done
affects: "transcription queue"
---

## What happens

Nothing coordinates `amanu process` with the running app over a session
folder. If both reach for the same recording, both transcribe it — and on the
cloud engine, both upload and both are charged.

## Why the window is small

The app scans the recordings folder at launch and on request, not continuously,
so the two have to be reaching for the same session at nearly the same moment.
Nobody has hit this.

## Why it is still open rather than fixed

Closing it properly is what the cancelled Unix socket would have been for, and
that decision stands (`CLAUDE.md`, "Two standing decisions"). A lock file in
the session folder would do it without reopening the socket argument, which is
the shape any fix here should take.

## Where

`Sources/amanu/Sessions/SessionInventory.swift` decides what is pending;
`Sources/amanu/Transcription/TranscriptionCoordinator.swift` runs the queue.

## What was done

Fixed on 20 August 2026, in the shape this note said any fix should take: a
lock file in the session folder, and no socket.

`.transcribing.json` sits beside `.recording.json` and copies its conventions —
dot-prefixed, `pid` and `started` and now a `stage`, pretty-printed with sorted
keys, and the same rules about a stale one. It is created with
`O_CREAT|O_EXCL` rather than written atomically, because unlike the recording
marker two claimants are genuinely possible and a write-and-rename would let
both believe they had won. An owner that is still alive means back off; an owner
that is gone means take it, log the reclaim, and go on; a claim that cannot be
read is left strictly alone, which is what `recoverInterrupted` does with a
manifest it cannot parse. Releasing only deletes a claim whose pid is ours, so a
process cannot delete one another process has legitimately reclaimed.

It is taken in `TranscriptionCoordinator.transcribe(_:)`, before the engine is
prepared, which is the single funnel both the app's queue and `amanu process`
pass through. Being refused is not a failure: `drain` catches it without calling
`recordFailure`, so repeated collisions cannot retire a session against
`maxAttempts`, and the folder stays where it is — the filesystem is the queue.
`resumePending` skips a claimed session so the menu bar stops counting work
another process owns.

The note underestimated the scope by one cost centre. `PostProcessor.finish` had
four unsynchronised callers making the same naming and summary calls, so it
takes the claim too, with `stage: "finish"`; that meant lifting the call out of
`transcribe`, since a claim held while asking for a second one would refuse
itself. `markForRetranscription` now refuses under a live claim instead of
deleting a transcript from under a run in flight.

What the terminal says, in English by the standing rule:

```
Another amanu (pid 67962) is already transcribing this recording. Let it finish, or quit it and run this again.
```

Ten tests, including one that spawns `/bin/sleep` so the live owner is a
genuinely foreign process rather than the suite itself.
