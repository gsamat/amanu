---
title: "Turning on the local engine downloads the model without choosing the engine"
date: 2026-08-20
status: open
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
