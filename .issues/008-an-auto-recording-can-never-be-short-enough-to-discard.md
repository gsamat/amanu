---
title: "An automatic recording can never be short enough to be discarded"
date: 2026-08-20
status: open
affects: "min_duration_seconds, and every brief join of a call"
---

## What happens

Measured on 0.4.2 build 197, across four real Zoom calls.

A nineteen-second join produced a kept session of ninety-nine seconds. All four
came out between 99 and 244 seconds. `min_duration_seconds` is 45, and nothing
was ever discarded.

The arithmetic is the whole story. The discard compares the length of the
*recording* against `min_duration_seconds` (45). But a recording that stops
because the call ended requires the microphone to have been idle for longer
than `stop_delay_seconds` (90), and the microphone cannot go idle before the
recording starts. So the shortest automatic recording that can exist is about
ninety seconds, and the discard branch is unreachable on the shipped defaults.

Nothing in `Tests/` covers that branch, which is why it has been unreachable
without anyone noticing.

## What it costs

The setup window promises "Recordings shorter than a minute are thrown away".
They are not. Every accidental join, every wrong meeting left after ten
seconds, is kept: audio, a folder, a place in the list.

Worse, they cannot be transcribed. A nineteen-second join with nobody speaking
came back from AssemblyAI as `language_detection cannot be performed on files
with no spoken audio`, so the session sits at `pending` rather than `failed`,
keeps its audio — 29 MB in the case measured — and stays in `~/Recordings`
looking like work that is still owed.

## What would settle it

Decide what the rule is actually about. If it is "a meeting is at least this
long", then the length to compare is the recording's, and the delay before
stopping has to come out of it before comparing. If it is "a call app opened
the mic and let it go again", then the length to compare is the call's, not the
recording's, and `AutoRecordController` already knows it.

Either way the test to write first is the one that fails today: an automatic
recording of a call shorter than `min_duration_seconds` leaves nothing behind.
