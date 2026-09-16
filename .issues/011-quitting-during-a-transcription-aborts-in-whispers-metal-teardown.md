---
title: "Quitting during a transcription aborts inside whisper's Metal teardown"
date: 2026-09-16
status: done
affects: "every quit that lands while the queue is working — a crash dialog for a quit somebody asked for"
---

## What happens

⌘Q during a local transcription ends in a crash report. The person sees the
dialog macOS shows for an abort, on a quit they meant, usually just after a
meeting — the moment when "amanu crashed" is least welcome and least believable.

The report reads as a race between two threads and is one:

- Thread 0, the main thread, is in `-[NSApplication terminate:]` → `exit()`, and
  from there in `__cxa_finalize_ranges` → the destructor of
  `std::vector<std::unique_ptr<ggml_metal_device>>` → `ggml_metal_device_free` →
  `ggml_metal_rsets_free` → `ggml_abort` → `abort()`.
- Thread 6 is inside `whisper_full` → `whisper_encode_internal` →
  `ggml_metal_synchronize`, waiting on an in-flight Metal command buffer.

Whisper's device is reachable from a module-level vector, so its destructor runs
at `exit()` whether or not amanu freed the context first. Freeing the residency
sets with an encode still in flight is what trips the abort. The report is from
0.4.25 (305) on macOS 27.0, and the video recorder was not involved: thread 6 is
the audio transcriber, which is what the queue runs after every finished
recording.

## What it costs

A crash dialog, and the habit it teaches. A quit that sometimes crashes is a quit
people learn to double-check, and the second thing they try after a suspected
hang is Force Quit — a hard kill of a recording, which is the one failure this
program is built to survive. No work was at risk in the meantime: the filesystem
is the queue, so a session stopped mid-transcription has no transcript and is
offered again by the scan at the next launch.

## What was done

Quitting already deferred AppKit's termination for an import in flight, so the
queue now gets the same treatment: `prepareForTermination` asks the coordinator
whether it is transcribing, cancels the drain, and waits for it before answering
AppKit. Whisper honours cancellation through its abort callback, so the wait is
seconds, and `whisper_free` — on the way out of the drain — runs while no encode
is in flight rather than underneath `exit()`.

Three things had to be true for that to be a fix rather than a delay:

- **A cancelled drain is not a failure.** Every engine reports the same cancel in
  its own dialect — whisper as a `CancellationError` after the abort callback, a
  cloud upload as a cancelled URLSession task — so the drain keys on the task
  being cancelled rather than on the error it surfaced. Counting it would spend
  one of the three attempts a session gets, and after three quits retire a
  recording that is perfectly fine and compress its audio under a transcript that
  was never written.
- **Nothing starts after the stop.** The quit closes a live recording on its way
  out, which enqueues the session it has just finished; on the SIGTERM path that
  enqueue lands while the deferred quit is waiting. The coordinator refuses to
  begin a drain once it has been told to stop, so the session is left without a
  transcript for the next launch's scan.
- **The wait is visible.** "Stopping the transcription…" goes up in the menu bar
  and the status window, so the seconds before the window disappears read as work
  rather than as a hang.

The deferral is now unconditional. Whether anything is in flight is a question
only the actors can answer, and they answer asynchronously; a cached flag that
said "idle" while whisper was mid-inference would reintroduce exactly this crash,
and one run-loop hop on an otherwise quiet quit costs nothing.

## The hang the fix introduced first

Answering AppKit's deferred request is a main-actor job, which is a main-queue
block, and the SIGINT/SIGTERM handlers are `DispatchSource` handlers — they run
*inside* a main-queue drain. libdispatch does not drain a serial queue underneath
itself, so a quit asked for from a signal handler sat in `_shouldTerminate`
forever: `kill -TERM` did nothing, and a logout would have hit it too. It has its
own entry in `docs/pitfalls.md`, with the measurement that settled it written out
there — a fifty-line app that asks for a deferred terminate from inside the
handler hangs, and the same one asking from the run loop's next turn quits.
`Run.quitFromTheRunLoop` now hands the quit to the run loop's own next turn,
where the reply arrives.

## Where

`Sources/amanu/Transcription/TranscriptionCoordinator.swift` — `stopping`,
`stopForTermination()`, the cancellation branch in `drain()`, and the injected
`enabled` seam the queue's tests need.
`Sources/amanu/Amanu.swift` — `prepareForTermination`, `finishForTermination`,
`quitFromTheRunLoop`, `setTranscriptionLine`.
`Tests/amanuTests/Sessions/QuitDuringTranscriptionTests.swift` — a queue stopped
mid-transcription, a cancelled cloud upload, and an enqueue that arrives after
the quit.

## Resolved

The installed 0.4.25 build was driven through both paths with a real local
whisper transcription in flight (a synthetic hour of audio, `large-v3-turbo-q5_0`
on Metal):

- the app's own quit path, sent as the Apple event `quit app "Amanu"` — the route
  the crash report shows (`MenuBarController.quitClicked()`);
- `kill -TERM`, which is what a logout or a reboot sends.

Both logged `transcription cancelled — the session stays pending`, both exited
within seconds, and no crash report was written either time. The session was left
with its audio, no `transcription_attempts`, no `transcription_failed`, no claim
file and no transcript — and the next launch picked it up and began transcribing
it again, which is the "nothing is lost" half of the claim.
