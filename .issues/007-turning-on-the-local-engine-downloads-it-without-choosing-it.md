---
title: "Turning on the local engine downloads the model without choosing the engine"
date: 2026-08-20
status: done
affects: "the transcription section of the setup form"
---

## What happens

Measured on 0.4.2 build 197, installed from the published disk image.

With parakeet absent, switch **On this Mac** on. The download starts from the
switch, exactly as designed: the bar advances and the count reaches
`460 of about 460 MB`. When it finishes the row says `downloaded · 461 MB`.

And the switch is still off. `config.json` still holds
`"transcription": {"engine": "assemblyai"}`, which is what "the local engine is
off" is written as. The choice the person made — the one that cost them 461 MB
and a minute of waiting — was not recorded.

Switching it on a second time works: `engine` is removed, both switches are on,
which is the fallback arrangement.

## Why it matters

The next meeting is transcribed in the cloud. Nothing says so. The person asked
for transcription that stays on their Mac, watched a progress bar fill on that
promise, and got the opposite — silently, and with their audio leaving the
machine, which is the one thing that switch exists to prevent.

It is also the more likely path than it looks: the natural moment to want local
transcription is the moment you notice it is not on, and that is exactly the
moment the model is missing.

## Where it is

`SetupForm`, the action behind the local switch. Turning it on when the model is
absent calls `downloadParakeetIfNeeded()`; what it does not do is write the
choice, and when the download finishes `refreshTranscription()` redraws the
switch from a config that never changed.

The neighbouring cloud switch has deliberate behaviour of this shape — it
refuses to turn on until a key works, because a switch that reads "on" while
every transcript fails with HTTP 401 is worse than one that refuses. Whether
the local switch should refuse the same way or write the choice and let the
download catch up is a decision, not an oversight to patch. What it does now is
neither: it accepts the click, does the expensive half, and drops the cheap one.

## What was done

Fixed on 20 August 2026, and the answer to the question at the end of this note
is the first of the two: write the choice, let the download catch up.

The bug turned out to be ordering, not a missing write. `localToggled` did call
`commitTranscription()` — but only after `downloadParakeetIfNeeded()`, whose own
`refresh()` redraws the switch from the config, putting it back off; the write
that followed then read the switch and saved the arrangement the click was
trying to leave. That also explains both observed details: a second toggle works
because the download is already in flight and the early return skips the
redraw, and a model already on disk skips it too. Swapping the two statements is
the whole fix, and it makes the local switch agree with the live-transcript
switch next to it, which has always written before downloading and has never had
this bug.

Refusing until the model arrived was the other candidate and was rejected. The
cloud switch refuses because a key cannot be obtained by waiting; a model can,
and this program downloads it unattended, including at transcription time. More
to the point, "chosen but not yet here" is a state the rest of the code already
models and repairs — `parakeetIsWantedAndMissing`, the footer's *One thing left*,
the delete-model alert's promise that it comes back at the next meeting — and all
of that machinery only works because the choice is on disk. Refusing would have
made the one honest state unrepresentable and stranded the intent in a variable
that dies with the window.

Four tests, and the seams to make them possible: the form's reads and writes of
the transcription section, and its two parakeet calls, are now injected closures
in the style of `isRecording`. That was the missing half — the ordering shipped
because a click that writes to the config file of whoever runs the suite cannot
be tested. The regression test fails without the reorder, with exactly the
symptoms measured here.
