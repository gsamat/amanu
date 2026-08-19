# The live pass

What to do to a running copy of amanu before believing a release. The setup
window has its own page — `setup-window-manual-checklist.md` — and this one is
everything that page cannot reach: a real recording of a real call, the models
arriving and leaving, the first run, and the command line.

Written after three releases in one night, every one of which shipped with
"nobody has clicked this" in its notes. Of the bugs those releases fixed, most
were found by opening a window and looking; none of the ones found that way had
a failing test first. That is the argument for this page.

## Before you start

**Check that nothing is being recorded**, like this:

```sh
amanu doctor | head -2
ls ~/Recordings/*/.recording.json
```

A session being recorded holds that file, with the owning pid and the moment it
started; it is written at the start and removed at the end. Nothing printed
means nothing is recording.

`amanu doctor` reads the same file and says so in its first line — `! recording:
in progress — 2026.08.20-1431 Standup (4:12)`, or `✓ recording: ok` when there
is nothing. A manifest whose owning process is gone is reported differently
again, as a crashed session the next launch will adopt. The `ls` is still worth
knowing: it works when the copy you are about to replace is not the one on your
PATH.

Do **not** use `amanu sessions` for this. It does not list a recording in
progress at all — `SessionInventory` filters on `meta.json`, which is only
written when the recording stops — so it answers "nothing is running" in
exactly the case where something is. `.issues/005` says it shows up as a
`pending` row; that was wrong, and this is the correction. The status window is
also honest, showing a running transcript and a live **Pause** button, but it
is a window and a script cannot consult it.

Quitting the application mid-recording has already cost somebody three minutes
of a conversation that cannot be recovered.

The cases below are grouped so that one person, or one agent, can hold the
application exclusively for a group and hand it on. Two things driving the same
windows at once produces results that mean nothing.

Install from the published disk image, not from `.build` — the thing under test
is what a stranger downloads:

```sh
hdiutil attach -nobrowse amanu-vX.Y.Z-macos-universal.dmg
rm -rf /Applications/Amanu.app && cp -R "/Volumes/amanu X.Y.Z/Amanu.app" /Applications/
hdiutil detach "/Volumes/amanu X.Y.Z"
spctl --assess -v /Applications/Amanu.app     # accepted, Notarized Developer ID
```

Note the build number (`CFBundleVersion`) and put it in the report. A result
against an unnamed build is a result about nothing.

---

## A. The windows, in both languages

Nothing here writes anything you would miss, so it goes first.

**A1 — Setup opens and is legible.** `amanu setup` in a terminal (the only door
once the first run is done). Confirm the window opens **in the application**,
not as a process in the terminal — the title bar belongs to Amanu and the icon
bounces in the Dock. Read every row. Nothing truncated with an ellipsis,
nothing overflowing its box, no text sitting on a separator.

**A2 — Every access row reports the truth.** Compare each row against System
Settings → Privacy & Security. Microphone, system audio, calendar, start at
login. A row that says "allowed" for something the system does not list is the
defect that shipped once already, when a copy run from a terminal read the
terminal's permissions.

**A3 — The footer says what is left.** With everything granted it reads
"Everything amanu needs is granted". Take one grant away in System Settings,
come back to the window, confirm the sentence names what is missing and the
button offers to fix it. Put it back.

**A4 — The same sentence under the Settings tab.** Open Settings → Setup.
The same sentence is under the form, without a button beside it.

**A5 — Two windows agree.** Open Setup and Settings side by side. Toggle **Keep
the audio after transcribing** in one; the other must follow immediately,
without being clicked and without being reopened. Then the other way. Then from
the Advanced tab. Then the live-transcript switch in the status window against
both forms.

**A6 — Redrawing writes nothing.** Note the modification time of
`~/.config/amanu/config.json`. Open both windows, switch tabs back and forth,
scroll, close and reopen. The modification time must not change. Two separate
paths used to rewrite the file just for being looked at.

**A7 — Russian.** Set `interface_language` to `ru` in Settings → Advanced →
Interface, restart, and read every window again: setup, both settings tabs, the
status window, the recordings window, the menu bar, the application menu. Any
English sentence left in a Russian window is a defect; the *names of languages*
in the meetings-language menu are not — those are deliberately autonyms, as in
Language & Region. Set it back to `auto` afterwards.

**A8 — Both appearances.** System Settings → Appearance, switch Light to Dark
with the windows already open. Borders and separators must survive. Switch
back. This broke once and was invisible until someone looked.

---

## B. The models, coming and going

**Destructive: this deletes more than a gigabyte and downloads it again.** Do
not start it on a metered connection or ten minutes before a meeting.

**B1 — What is on disk.** Settings → Advanced, bottom. Each model with its
size, the total, the path. Compare against `du -sh ~/Library/Application\
Support/FluidAudio/Models/*`. The numbers are measured, so they should agree
exactly, not approximately.

**B2 — Deleting asks.** Press **Delete** on the local transcription model.
Confirm there is a confirmation and that cancelling it deletes nothing.

**B3 — Deleting turns off what wanted it.** Delete it for real. The switch that
required the model must turn itself off, and `config.json` must say so.
Otherwise the model downloads itself again at the next meeting and the space
comes straight back — which is the whole reason the switch is touched.

**B4 — The block updates itself.** The row goes, the total drops, and the disk
agrees.

**B5 — Downloading from the switch.** Turn **On this Mac** back on. The
download starts from the switch alone — there is no Download button. The
progress bar and the megabyte count both advance, the window stays responsive,
and the bar reaches its end rather than stopping short: it counts towards
461 MB, which is what the model actually weighs.

**B6 — The footer notices.** While the model is missing and the switch is on,
the setup footer names it and the button offers **Download parakeet**.

**B7 — The same for the live model.** Delete and re-download the live
transcription model, and confirm the live-transcript switch behaves the same
way.

**B8 — A leftover version is visible.** If `transcription.model` has ever been
changed, the abandoned version appears in this block with its size. This is the
only place in the program where it is visible at all.

---

## C. A real call, end to end

This is the case that cannot be faked, and the only one that exercises audio.
Use a meeting nobody else is in.

**C1 — Auto-record starts.** Join the call. Within about fifteen seconds the
menu bar says it is recording and the status window shows a running transcript
and a **Pause** button. `start_delay_seconds` and the five-second poll together
set that delay.

**C2 — Both sides are captured.** Speak into the microphone, and have the far
side make sound too. In the status window both should appear, attributed to
**me** and **them**. A far side that comes out as silence is the failure this
project has been surprised by before — see `rca-002`.

**C3 — The live transcript runs.** Text appears while the call is happening,
not only afterwards.

**C4 — Leaving stops it.** Leave the call. Recording stops within about ninety
seconds — that is `stop_delay_seconds`, waiting to see whether the call really
ended.

**C5 — The transcript folds away.** With the recording stopped, the live
transcript section collapses and the window returns to its previous height. A
link in the section header brings the text back, and hides it again.

**C6 — The work finishes.** The session transcribes and a summary is written.
Watch `amanu sessions` go from `transcript: pending` to `done`, and read what
lands in `~/Recordings/<session>/`: `transcript.md`, `summary.md`, and the
audio only if **Keep the audio** is on.

**C7 — The transcript is not nonsense.** Read it. A meeting held in English
with the meeting language set to Russian used to come back as fluent-looking
Cyrillic, unrecoverably, because the audio was already deleted. That is fixed;
this is the case that proves it. Try it in the other language too.

**C8 — The recordings window.** Open it. The session is listed with its
duration, its state, and the speakers. Rename a speaker and confirm it reaches
`speakers.json` and the transcript. In Russian the window says «я» and
«они A» while the files keep `me` and `them A` — the letter is what ties one to
the other.

**C9 — A short call is thrown away.** Join and leave inside `min_duration`
(45 seconds by default). No session should be kept.

---

## D. The first run, and the command line

**D1 — `amanu setup` on a Mac with nothing running.** Quit the application
first. The command must open the application rather than becoming a process in
your terminal, and it must not fail. Both halves were broken until recently:
the branch that starts the application itself had never worked, and once it did
it read the terminal's permissions instead of its own.

**D2 — The menu item comes and goes.** With setup complete, **Setup…** is in
neither menu. `amanu setup` puts it back — it clears the completed mark — and
pressing **Done** takes it away again without a restart. Settings never
disappears.

**D3 — `amanu doctor` on both architectures.** Run it, and run it again under
Rosetta:

```sh
arch -x86_64 /Applications/Amanu.app/Contents/MacOS/Amanu doctor
```

The Intel slice should report the cloud engine, because the local models are
refused there. Both should agree with what the windows say. The first line is
about a recording in progress and reads `✓ recording: ok` when there is none;
`amanu setup` prints the same line, and only when it is not ok.

**D4 — The command line is English.** Deliberately: it ends up in bug reports
and half of it is the names of things. Confirm it stays English even with the
interface set to Russian.

**D5 — Updating.** Keep an older build installed and use **Check for
updates…**. It should find the new version, render the notes as HTML, download,
verify, install and relaunch. This is the only check that exercises the whole
release chain at once.

---

## Reporting

Say the build number, say what you did, and say what you did not do. A pass
with three cases skipped and named is worth more than a pass with three cases
quietly missing — every release this page came out of said "nobody has clicked
this" somewhere in its notes, and each time that sentence was the most useful
one in the document.
