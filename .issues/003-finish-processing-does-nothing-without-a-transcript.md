---
title: "Finish processing does nothing on a settled session with no transcript"
date: 2026-08-19
status: done
affects: "the recordings window"
---

## What happens

**Finish processing**, in the recordings window, completes the work a session
still owes: names, a summary. On a session that has settled without a
transcript at all, it does nothing and says nothing.

## Why

`amanu process` had the same gap and no longer does — it was given a route
back to the stereo archive, and refuses with a reason when the audio was
discarded. The window's button was not carried along.

## Why it is not urgent

**Re-transcribe** covers the case from the same window, and the CLI covers it
from a terminal. This is a button that should either do the obvious thing or
say why it cannot, rather than a hole in what amanu can do.

## Where

`Sources/amanu/UI/RecordingsWindow.swift`, and the route to copy is the one
`ProcessSession` takes in `Sources/amanu/Sessions/SessionCommands.swift`.

## What was done

Fixed on 20 August 2026. `finishClicked()` no longer calls `PostProcessor.finish`
blind. It asks `PostProcessor.plan(for:)` — the same question `amanu process`
asks — through a pure `RecordingsWindow.decision(for:policy:)`, and then does one
of four things: runs the work and keeps the `Work` it gets back, sends the
session for transcription the way the Re-transcribe button already does (with no
confirmation, because there is no transcript to lose), refuses with a reason, or
says nothing was owed.

The refusals had to be said in the window's language, and the ones `plan`
returned were English by the standing rule that terminal output stays English.
Rather than have the window compose its own sentences and risk the two reaching
different conclusions about the same folder — the thing `plan`'s comment exists
to prevent — `Obstacle` and a new structured `Refusal` now carry `described`
beside `description`, which is the pair `SessionInventory.Step` already uses. The
command line prints byte-identical English to what it printed before. The one
deliberate difference is the retired session: the window names the
**Re-transcribe** button where the terminal names `amanu process --again`.

Five tests, four of them in `RetranscriptionTests` next to the `plan` coverage
they mirror, one in `InterfaceLanguageTests` for both languages of the refusal.
