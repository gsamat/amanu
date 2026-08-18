---
title: "The CLI and the running app can transcribe the same session twice"
date: 2026-08-19
status: open
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
