---
title: "A silent system track is only ever caught at setup, and not at all under system_audio: all"
date: 2026-08-20
status: done
affects: "the far end of every meeting after a permission is revoked"
---

## What happens

`.issues/rca-002-system-tap-silent-outside-launchagent.md` is closed: the bare
binary it describes is gone, the bundle is signed with an identity TCC can
attribute, and `spike/tcc-bundle` measured it capturing at 100% non-zero
samples. What that note got right and is still right about is the shape of the
failure — an unauthorised process tap does not fail. It returns `noErr`, reports
a correct 2 ch / 48 kHz format, starts, fires its IO proc at the right rate for
the whole meeting, and every sample is zero.

So the question is not whether the grant is there today. It is what the person
sees on the day it goes away — after an OS update, a re-signing, a `tccutil`
reset, or a hand slipping in System Settings. `docs/pitfalls.md` records that
amanu has already lost its grants once, on 18 August 2026, when signing moved.

Three things stand between that and a meeting recorded with no far end, and
none of them is running while the meeting is.

**The tone test is a setup-window thing.** `SetupPermissions.testSystemAudio()`
does the honest experiment — starts a real tap, plays 440 Hz through the default
output, and answers `heard`, `silent` or `refused`. It is called from the setup
form, which is a first-run window, and its answer is cached for thirty days.
Nothing re-runs it, and `amanu doctor` does not read even the cached answer: it
still says the grant state is unknowable until first use, which was true before
this test existed.

**The in-recording warning does not fire for everyone.** `RecordingSession`
will say something when you have spoken recently and the far end has been silent
for five minutes — but the first line of that check returns unless the tap is
scoped to particular apps. With `system_audio: "all"` there is no far-end
silence check at all.

**The stall watchdog cannot see it.** It polls the size of each `.caf` every
fifteen seconds, and a digitally silent track grows at exactly the normal rate.

## What it costs

One meeting, in full, discovered at transcription time as a transcript with
nothing from anyone else in it — which is the same cost rca-002 measured, minus
the cause it blamed.

## What would settle it

The cheap half is `doctor`: report what `testSystemAudio` last found and when,
rather than reporting that nothing can be known. A line saying the tone was last
heard eight days ago is a fact; "unknowable until first use" is not, any more.

The honest half is a level check on the system track during the recording — the
peak over the first seconds of tap callbacks, and a notification if it is
exactly zero. `MicRecorder` already does this for the mic and rca-001 is why.
Unlike the mic there is nothing to fall back to, so the correct action is to say
so loudly rather than to recover quietly.

Dropping the `apps`-only guard on the far-end silence warning is a smaller
version of the same thing and would help the `all` case immediately.

## Where

`Sources/amanu/Setup/Permissions.swift` — `testSystemAudio()`, and the thirty-day
memory of its answer.
`Sources/amanu/Doctor.swift` — `checkSystemAudio`, which does not ask it.
`Sources/amanu/RecordingSession.swift` — the far-end silence warning and its
scope guard.
`Sources/amanu/Audio/SystemAudioRecorder.swift` — where a peak over the first
seconds would go.

## Resolved

The system tap now records whether any non-zero sample has arrived and warns
after its initial grace period when the growing track is digital zero. The
five-minute far-end warning applies to both app-scoped and all-system capture,
and `amanu doctor` reports the age of the last successful tone test. Tests cover
digital zero, a non-zero quiet signal, the grace period, both capture scopes,
and the remembered doctor result.
