---
title: "An automatic recording can never be short enough to be discarded"
date: 2026-08-20
status: done
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

## What was done

Fixed on 20 August 2026. Of the two rules this note offered, the first was
taken: the length to compare is the recording's, with the delay before stopping
taken out of it first.

Which delay is known from the reason the recording ended — `stop_delay` for
`call-ended`, `silence_stop` for `silence`, sixty seconds for
`calendar-event-ended` — so the measured case is 99 seconds less the 90 it spent
waiting, which is 9, which is under 45, and it goes. The alternative, comparing
the call's length, would have meant retaining the start of the mic-busy interval
across the transition that throws it away and widening a callback shared with
the manual-recording ceiling, and it would still have needed a fallback for a
recording the calendar started and the microphone never triggered.

The decision now lives in `AutoRecordController.shouldDiscard(trigger:reason:
duration:settings:)`, taking its settings as a parameter so a test needs no
config file — which is the part that matters, because this branch shipped
unreachable precisely because nothing could call it. The calendar rule's bare
sixty seconds became a named constant used by both the stop rule and the discard
rule, so the two cannot drift apart the way this note describes. The caveat is
written into the code: measuring from the recording's start under-counts the
meeting by up to `start_delay` of pre-roll, which errs toward discarding.

Eight tests, the first of them the nineteen-second join exactly as it was
measured. It fails against the old comparison.

The window no longer promises a minute it did not mean: **A call shorter than 45
seconds is thrown away** / **Звонок короче 45 секунд выбрасывается**, and the
settings row now says the wait before stopping does not count.

The second half of the note is fixed too. AssemblyAI's
`language_detection cannot be performed on files with no spoken audio` is now
permanent, so a session with nothing in it is `failed` on the first attempt
rather than uploaded and paid for twice more before retiring.
