# Where amanu stands, and what is left

Written 19 August 2026, at the point where amanu became `Amanu.app`. This is
the state of the machine and of the tree, what was measured rather than
assumed, and what the next session should pick up — with enough detail that
nobody has to reconstruct it from commit messages.

## The short version

amanu is now an ordinary macOS application. It records both sides of a
meeting, transcribes them, names the speakers, and writes a summary; the audio
is archived as one stereo M4A or discarded, and there is an optional live
transcript in the status window. The LaunchAgent it used to need is gone.

What is *not* done is everything about shipping it: no DMG for the app, no
notarization pass, no updater, no release. The last public release, v0.1.0, is
still the bare binary.

## The state of this machine

Not the same thing as the state of the repository, and worth knowing before
changing either.

- `/Applications/Amanu.app` is installed, running, and registered at login
  through `SMAppService`. `Login Items` in System Settings shows it.
- `~/Library/LaunchAgents/me.samat.amanu.plist` is **gone** — the app retired
  it on first launch. The binary it used to start was moved to
  `~/.local/bin/amanu.legacy-20260818`. Nothing writes a LaunchAgent any more:
  the code that did was deleted, and `LegacyMigration` is the only place that
  still knows the plist's name, so it can take one off a machine that has it.
  Delete that too once the first native release has been out for a while.
- `~/.local/bin/amanu` is a symlink into the bundle. Scripts and agents that
  call `amanu …` still work, and they now reach the same executable the app
  runs.
- Keys live in `~/.config/amanu/keys/` (0700, one 0600 file per service). The
  shared `~/.config/assemblyai/token` is still read as a fallback and is what
  the `transcribe` skill uses; amanu never writes there.
- The AssemblyAI key was found in `~/Documents/проекты/new_secretary_bot/.env`
  after the old one was overwritten with two bytes. It is valid again in both
  places.
- Test recordings from this session are still in `~/Recordings`:
  `2026.08.18-2300`, `-2308`, `-2310`, `-2344`, `-2344-2`, `-2349`. All of them
  are synthesised speech, not meetings. Safe to delete.

## What was measured, not assumed

Three things had never been checked and now have been. Each one is worth
re-checking the same way if the surrounding code changes.

**A signed bundle captures system audio.** The old RCA
(`.issues/rca-002-system-tap-silent-outside-launchagent.md`) proved a
*terminal-launched binary* records silence, and the LaunchAgent existed to work
around it. `spike/tcc-bundle` plays a 440 Hz tone into its own global tap and
counts the samples that come back: 100% non-zero, and the tap also hears other
processes (checked by speaking through `say` from a separate process and
measuring the energy that isn't at 440 Hz). Then the same thing was measured on
amanu itself — a test recording's far-end track came back at −17.6 dBFS.
`spike/tcc-bundle/RUNBOOK.md` has the procedure and the rollback.

**The stereo archive works end to end.** A real 75-second recording settled
into one `audio.m4a`, 20.6 MB of PCM down to 1.2 MB, and the two channels match
the original tracks: left is the microphone, right is the far end, RMS and peak
identical to the sources.

**Live transcription runs on the real model.** Nemotron 1120 ms streaming,
loaded from the FluidAudio cache, both sides transcribed, Russian text in the
window within a couple of seconds. It had never been run before — the whole
feature had been tested against a fake engine.

## What is left, in the order I would do it

### 1. The login-item half of the TCC question

Registration is done and `SMAppService.mainApp.status` reports enabled, but
nobody has logged out and back in to confirm that the copy macOS starts at
login also captures system audio. The spike has a button for exactly this
(**Register login item**, then a real logout). Until someone does it, autostart
is the one part of the architecture that rests on reasoning rather than
measurement.

### 2. Release the application

Nothing here is designed yet beyond the chapter in
`docs/superpowers/specs/2026-08-18-native-macos-app-design.md`.

- A DMG containing `Amanu.app` and an `/Applications` shortcut, signed and
  notarized, with the ticket stapled. `notarytool` uses the same App Store
  Connect key as the iOS projects (`~/.appstoreconnect/private_keys/`, and
  `.env.asc` in any iOS repo has the ids).
- `CFBundleVersion` currently comes from `git rev-list --count HEAD` and
  `CFBundleShortVersionString` from `VERSION` in the Makefile. Decide whether
  that is the versioning story before the first release, because the updater
  will compare those numbers forever.
- A GitHub release with the DMG and its checksum. The existing v0.1.0 release
  notes describe copying a binary out of a disk image; the new ones describe
  dragging an app, and should say what happens to the old installation (it is
  retired automatically — see `LegacyMigration`).

### 3. Sparkle, or a deliberate decision not to

The spec commits to Sparkle with an EdDSA-signed appcast at
`https://samat.me/amanu/appcast.xml`, served from `gsamat/samatme3` and
deployed to `reina:/var/www/samat/amanu/` by a narrow rsync (the site's own
deploy uses `--delete` and would remove an untracked file). None of it exists.
It is also the largest remaining piece for a program with one user plus
whoever finds it on GitHub — worth confirming it is wanted before building it.

### 4. Re-transcription from the archive, from the CLI

`amanu process` reports `transcript: pending` on a settled session and then
does nothing, because only the recordings window knows how to re-transcribe
from `audio.m4a` (through `AudioChannelExtractor`, which pulls one channel out
into a temporary mono file). The extraction path itself is exercised by
`TranscriptionCoordinator.transcribePerTrack`; what is missing is the route
into it from `process`.

### 5. Speaker naming quality

Sessions from 18 August show `names: failed 0/6` and `named 0 of 1`. The
speaker-naming work is codex's, it is merged, and nobody has looked at why it
names nothing. Start with `speakers.json` and `SpeakerNamer`, and with a
session that has a calendar-derived attendee list.

### 6. Live transcript on a real meeting

It works on synthesised speech and in the app. It has never run against a real
Zoom call, where the far end is a person and the near end has echo
cancellation. Watch for: the `You`/`Them` labels being right, blocks arriving
in the order they were spoken, and the drop counter (`dropsBeforeGivingUp`)
staying quiet on a busy machine.

### 7. The manual checklist

`docs/testing/setup-window-manual-checklist.md` has never been run end to end.
Parts of it are stale — the window it describes was relaid out — and it should
be corrected as it is executed.

### 8. Two deviations from the spec, on purpose

`docs/superpowers/specs/2026-08-18-native-macos-app-design.md` has been
corrected to describe what exists, and says why in the sections concerned. The
two places it no longer asks for what it originally did:

- the bundle is assembled by `make app` around the SwiftPM binary rather than
  by an Xcode target, because the package already builds and tests with SwiftPM
  and a second build system would have to be kept in step with the first;
- control is the distributed-notification doorbell `amanu setup` already used
  (`SetupRequest`, `RecordRequest`, `SingleInstance`) plus a symlinked CLI.
  The socket the spec once asked for is not being built — it is a day of work
  and a suite of tests for something scripts on this machine already have.
  Don't resurrect it; if some future requirement genuinely needs structured
  errors or streaming status, that is a new decision to argue for on its own
  merits, not a plan left half-finished.

## Things that will bite

- **App Nap.** The app holds a `userInitiated` activity for its whole life, and
  a sleep-blocking one while recording. Remove either and the symptoms are
  confusing: IPC that answers seconds late, timers that drift, a request that
  is obeyed after the caller has given up. This is what made
  `amanu record start` report "amanu isn't running" while starting a recording.
- **`Bundle.main` and the symlink.** The CLI reaches the executable through
  `~/.local/bin/amanu`, and Foundation answers for the path it was invoked
  through. `Runtime.appBundle` resolves the link before deciding whether this
  is an app; anything that asks "am I bundled" must go through it.
- **TCC and the code signature.** Grants are keyed to the Developer ID
  signature and `me.samat.amanu`. Both were kept across the move to a bundle,
  which is why the microphone grant survived. Changing either re-prompts for
  everything — it happened once already, on 18 August, when signing moved to
  Developer ID.
- **Nothing writes to shared key files.** If a future feature needs a key, put
  it in `Config.keysDir`. The two-byte AssemblyAI key that broke every
  transcript for an evening came from the setup window writing into a location
  other tools also write to.
- **`swift test` needs `AMANU_NO_NOTIFY=1`**, or the suite posts banners.

## How to work on it

```sh
make                           # build + sign .build/Amanu.app
cp -R .build/Amanu.app /Applications/   # replace the installed copy
open /Applications/Amanu.app
AMANU_NO_NOTIFY=1 swift test   # 124 tests
```

The app writes nothing to a log file of its own; launch it with
`open --stdout out.log --stderr err.log /Applications/Amanu.app` when you need
to see what it says. `amanu record start|stop` drives it without a mouse, which
is how the recording paths above were verified. A recording made by hand is the
only way to test the audio paths; the tests cover everything else.
