---
title: "Finish processing does nothing on a settled session with no transcript"
date: 2026-08-19
status: open
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
