A release about promises the program was making and not keeping. The switch
that said transcription would stay on this Mac downloaded the model and then
chose the cloud. The setting that said short recordings are thrown away could
never throw one away. A button offered to finish work it then did nothing
about, in silence. Each of those was found by using amanu rather than by
reading it, and each is fixed here.

## What changed since v0.4.2

- **Turning on the local engine now chooses it.** With parakeet missing,
  switching **On this Mac** on started the download, filled the bar to
  `460 of about 460 MB` — and left `config.json` still saying `assemblyai`.
  The next meeting went to the cloud, silently, which is the one thing that
  switch exists to prevent. The click was not lost on the way to the config; it
  was overwritten. Starting the download redraws the form so the footer can say
  what is happening from the first second, that redraw read the switch back
  from a config that still said cloud, and the write that followed then saved
  the arrangement the click was trying to leave. It writes the choice first
  now, and the download catches up.

- **A short call is thrown away, which it never once was.** The rule compares a
  recording's length against `min_duration_seconds`, 45 seconds by default. But
  a recording that stops because the call ended must first sit through
  `stop_delay_seconds` of quiet — 90 — and the microphone cannot go idle before
  the recording starts. So the shortest automatic recording that could exist
  was about ninety seconds, the branch that discards one was unreachable, and
  four real calls came back between 99 and 244 seconds with a nineteen-second
  join among them. The wait now comes out of the length before it is compared:
  99 less the 90 spent waiting is 9, and 9 goes. The setup window no longer
  promises a minute it did not mean.

- **A recording with nobody speaking in it fails once instead of three times.**
  AssemblyAI answers such a file with `language_detection cannot be performed
  on files with no spoken audio`, which was treated as a passing difficulty, so
  the session sat at `pending` looking like work still owed and was uploaded
  and paid for twice more before retiring. A server saying there is nothing
  here to transcribe is now as final as our own verdict.

- **Finish processing says why it cannot.** On a session that settled with no
  transcript at all, the button did nothing and said nothing. It now asks the
  same question `amanu process` asks and either does the work, sends the
  recording for transcription, refuses with a reason, or says nothing was owed
  — and says it in the window's language.

- **amanu says out loud when a recording is running.** Quitting during a
  meeting now asks first, naming how long it has been going and what quitting
  costs: the session is saved either way, and nothing is recorded until amanu
  runs again. `amanu doctor` answers the same question in its first line,
  before anything else, and so does `amanu setup`. This one is here because of
  a specific morning — a quit during a call to test a build, and three minutes
  of the conversation gone.

- **The command line and the running app can no longer both transcribe one
  recording.** Nothing coordinated them, so both could upload the same audio
  and both be charged. A session is claimed in its own folder before the work
  starts, in the shape the recording marker already uses, and a claim whose
  owner has died is reclaimed rather than honoured forever.

- **An About window**, opened from either menu — the application menu where
  every Mac keeps it, and the menu bar menu because an accessory app's
  application menu is only on screen while one of its windows is in front. It
  says what amanu is, which version this is, and where it comes from.

- **The Advanced tab stopped repeating the Setup tab.** One window asked for
  the recordings folder twice, offered two switches for the same cloud engine,
  and put config-vocabulary pop-ups beside the plain-language form that meant
  the same thing. Eight settings now appear only where they are asked properly.
  They are still in `config.json` and still documented; only the repetition is
  gone.

## What the review found and did not fix

The eight entries in `.issues/` were each checked against the code rather than
taken at their word, and two turned out to be answered already.

The note saying the daemon ignores `SIGTERM` proposed a handler that had been
there since two days before the note was written, in the very build it was
written against. What a kill mid-recording actually leaves is a session the
next launch adopts — the tracks are uncompressed and written per callback,
which is why the format was changed away from AAC in the first place. The
observation itself remains unexplained, and the likeliest reading is that the
signal went to the terminal copy rather than the app.

The post-mortem about system audio recording silence outside a LaunchAgent
describes a program that no longer exists: no bare binary, no LaunchAgent, no
Info.plist smuggled in through linker flags. Its recommendation for `doctor`
was measured and is wrong, and the closing note says which test does work.

Two new entries were written for what survived. Only launching the application
recovers an interrupted session — `amanu process` still says a folder full of
audio does not look like a recording. And the tone test that would catch a
silent system track runs once, in a first-run window, and not at all for anyone
who has set `system_audio` to `all`. Neither is fixed here.

## Honest about what is untested

**No meeting was recorded for this release.** Everything above was reached by
tests, by reading, and by rendering the windows off screen. The audio paths
cannot be exercised any other way than by holding a real call, and none was
held. `docs/testing/live-pass.md` is the list of what that would have covered,
and its first two items are the ones this release changes.

**The discard now happens ninety seconds after the call it discards.** A tester
watching the timer will see a minute and a half of recording before anything is
thrown away, and may conclude it failed. The checklist says so now.

**The quit alert has not been dismissed by a person.** The decision behind it
is tested away from AppKit, as the update gate's is; the modal itself is a
manual step.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image carries
a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.4.3-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.4.3-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.4.3-macos-universal.dmg`
