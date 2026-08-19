---
title: "The daemon does not answer SIGTERM, and nobody has asked what that costs a recording"
date: 2026-08-19
status: open
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
