---
title: "The daemon does not answer SIGTERM, and nobody has asked what that costs a recording"
date: 2026-08-19
status: done
affects: "a recording in progress when the Mac logs out, restarts or shuts down"
---

## What was seen

While checking that `amanu setup` works on a Mac with nothing running, the
command did what it now promises and became the application. Killing it
afterwards took `SIGKILL`: `SIGTERM` was sent first and the process stayed.

That is the whole observation. It was made on 0.4.0 build 161, on an idle
process with no recording in progress, and it was not repeated.

## Why it might matter

macOS sends `SIGTERM` before it sends `SIGKILL` when a session ends — logging
out, restarting, shutting down. A process that ignores the first one gets a
few seconds and then the second one, which cannot be caught.

amanu writes audio while it records. What a `SIGKILL` mid-recording leaves
behind is exactly what nobody has looked at: whether the CAF files are
readable, whether the session is left owing work it can be told to finish
later, or whether it is left in a state the inventory does not recognise at
all. The answer could be "nothing is lost, the files are streamed and the
session settles on the next launch" — that would be worth knowing too, and it
is not written down anywhere.

## What would settle it

Start a recording, send the process `SIGKILL`, and look at what is on disk:
does `amanu sessions` see it, does **Finish processing** get anywhere with it,
do the tracks decode. Then decide whether a `SIGTERM` handler that stops the
recording cleanly is worth having, or whether the recovery path already
covers it.

Related: `004-cli-and-app-race-for-the-same-session.md` is about two processes
disagreeing about one session; this is about one process disappearing in the
middle of it. `005-a-recording-in-progress-is-invisible-…` is the same evening
from the other end: a recording was cut by a deliberate quit, which at least
recorded `"stop_reason": "app-quit"` — the question here is what a kill that
nothing can catch leaves behind instead.

## The answer, and why this closes

Answered on 20 August 2026 by reading the code, not by repeating the
observation.

**A `SIGTERM` handler was already there, and was there in the build this was
seen on.** `Run.runMain()` installs a `DispatchSource` signal source on the main
queue for `SIGTERM`, calls `controller.shutdown()` from it, and only then sets
`signal(SIGTERM, SIG_IGN)` so the default disposition cannot kill the process
first — the comment above it names logout, restart, `launchctl kickstart -k` and
`amanu install --uninstall` as the cases it exists for. `SIGINT` and `SIGUSR1`
are handled the same way. That source was added in `5e7709e` on 17 August 2026,
two days before this note was written and before v0.4.0 was tagged, so build 161
contained it. The thing this note proposed already existed when it proposed it.

**What a `SIGKILL` mid-recording leaves is a recoverable session, and that was
measured rather than reasoned.** The tracks are 16-bit LPCM in CAF, written
straight through on every capture callback, and CoreAudio leaves the data chunk
size open while the file is being written — so whatever reached disk decodes.
This is the reason the format was changed away from AAC: the experiment on
17 August 2026, recorded in the README, killed an AAC CAF mid-file and got
`estimated duration: 0.000000 sec` out of `afinfo`. `meta.json` is still written
only at a clean stop, so the folder is invisible to `amanu sessions` until
`RecordingSession.recoverInterrupted(root:)` runs at the next launch, adopts it
with `"stop_reason": "recovered-after-crash"`, and hands it to the queue.
`Tests/amanuTests/RecordingRecoveryTests.swift` has covered that path all along.

So the question this note was opened to ask — handler, or recovery path? — has
both answers, and neither of them is missing.

**What is left unexplained is the observation itself**, and it is worth naming
because it cuts the other way from the design. `signal(SIGTERM, SIG_IGN)` means
that if the main queue is ever not being drained, the process is not slow to die
but immune, and the symptom is exactly the one seen: `SIGTERM` ignored,
`SIGKILL` required. The likeliest reading is simpler — after `amanu setup`
learned to hand off to `Amanu.app` through LaunchServices the terminal copy
exits, so there are two plausible pids on screen and the wrong one may have been
signalled. It was seen once, on an idle process, and not repeated. That, and the
smaller gaps found while answering this, are written down in
`009-nothing-but-the-app-recovers-an-interrupted-session.md` rather than kept
here under a title that is no longer true.
