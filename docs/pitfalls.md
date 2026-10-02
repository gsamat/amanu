# Things that will bite

Constraints that are not visible from the code that depends on them. Each one
was paid for once. Breaking any of them compiles, passes the tests, and fails
somewhere else — usually on somebody else's Mac, usually with a symptom that
points at the wrong thing.

For help running Amanu, see [Troubleshooting](../SUPPORT.md#troubleshooting).
This document is for people changing the implementation.

## App Nap

The app holds a `userInitiated` activity for its whole life and a
sleep-blocking one while recording. Remove either and the symptoms are
confusing rather than obvious: IPC that answers seconds late, timers that
drift, a request obeyed after the caller gave up.

## `Bundle.main` and the symlink

The CLI reaches the executable through `~/.local/bin/amanu`, and Foundation
answers for the path it was invoked through — a plain directory, not a bundle.
`Runtime.appBundle` resolves the link before deciding. Anything asking "am I
bundled" must go through it rather than consulting `Bundle.main` itself.

This is load-bearing well beyond the question it looks like. Login-item
registration, notifications and system-audio capture all depend on the answer.

## Starting amanu from a shell gives its permissions to the shell

TCC answers a request against the *responsible* process, and a program started
from a terminal is the terminal's responsibility. `.issues/rca-002` measured
that with a bare binary; it is just as true of the signed bundle. Measured on
19 August 2026 with a signed, entitled bundle that had no TCC record at all,
reading its own calendar authorization:

| started by           | ppid  | XPC_SERVICE_NAME | answer |
|----------------------|-------|------------------|--------|
| shell                | shell | `0`              | full access |
| shell, double-forked | 1     | `0`              | full access |
| LaunchServices       | 1     | `application.…`  | not determined |

"Full access" there is the terminal's grant, read back by a program nobody has
granted anything. That is the trap: not a refusal, but a confident yes to a
question about somebody else — the setup window would show green rows for
grants amanu does not have, and remember a system-audio test the terminal
passed on its behalf.

Two things follow. The parent process id cannot be used to tell the cases
apart: double-forking reparents to launchd and changes nothing about who is
responsible. And `Run` hands over to LaunchServices rather than becoming the
app when it was not started by it, so `amanu setup` out of the README is safe
on a machine where nothing has been granted yet.

## TCC is keyed to the code signature

Microphone and system-audio grants belong to the Developer ID signature and to
`me.samat.amanu`. Change either and macOS re-prompts for everything, leaving
the old grant behind as a dead entry in System Settings. It has happened once,
on 18 August 2026, when signing moved to Developer ID.

The corollary is the good news: the designated requirement is the identity and
not the hash, so grants survive ordinary rebuilds and survive a Sparkle
update — measured, not assumed.

## The hardened runtime closes every resource it is not told about

The entitlement in `Packaging/Amanu.entitlements` is not only about the
microphone. Under the hardened runtime, EventKit is closed the same way — and
it fails silently: without
`com.apple.security.personal-information.calendars`, `requestFullAccessToEvents`
returns false at once, with no error, no system prompt and no entry in the TCC
database, so the setup window's Calendar button looks like a button that does
nothing. Measured on 19 August 2026 with two otherwise identical signed
bundles. Anything else amanu learns to ask for needs its entitlement added here
as well as its usage string in `Packaging/Amanu-Info.plist`; the plist alone
buys nothing.

The same day taught the sequel: once the prompt is answered, EventKit keeps
reporting `notDetermined` from `authorizationStatus` for the rest of the
process's life, while tccd has already recorded the grant. Believe the answer
the request itself returns, not a status read afterwards.

## Nested code is signed innermost first

`codesign` seals what it finds. Sparkle's framework signed *after* the app that
contains it silently invalidates the app's own seal. The failure does not
appear here — it appears as a Gatekeeper rejection on somebody else's Mac,
after the release is public. `make app` signs in the right order; keep it.

## The release binary is not at `.build/release/amanu`

The build is universal, and the two `--arch` flags that make it so move the
product to `.build/apple/Products/Release/amanu`. A stale single-architecture
binary can still be sitting at the old path from an earlier `swift build`, and
nothing about copying it into the bundle looks wrong: it signs, it notarizes,
it launches here. It is arm64 only, and it fails on exactly the machines the
universal build exists for. `make app` checks both slices are present for this
reason; keep the check if you touch the target.

## Nothing writes to shared key files

`~/.config/assemblyai`, `~/.config/anthropic` and `~/.config/openai` are read,
never written — both the `token` filename the CLIs write and the `api_key` one
people write by hand. Several unrelated tools share those paths, and that is how a
working AssemblyAI key became two bytes one evening and every meeting after it
failed with HTTP 401. If a feature needs to store a key, it goes in
`Config.keysDir`.

## Only one OpenAI transcription model is usable

`gpt-transcribe`, `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` return
running text with no timings at all — amanu cannot use them for anything, no
matter how good the text is: a transcript with no clock can be neither lined
up with the recording nor attributed to a speaker.
`gpt-4o-transcribe-diarize` is the one that returns timed segments *and*
speakers, and `chunking_strategy` is required with it for any audio over 30
seconds — without that field the API answers 400 rather than transcribing.

Its 25 MB per request is a real limit, not a guideline: the mix reaches it at
around 55 minutes, so `AudioSlicer` cuts longer meetings up. Speaker labels are
per request, so they are prefixed per piece rather than merged — the "A" of the
second piece is not the "A" of the first, and treating them as one person would
hand two strangers one name. That is not a theory: a four-minute mix run
through the real API in four pieces on 19 August came back with the Russian
voice labelled `1A` in the first piece and `4B` in the last.

Both paths have been run against the API for real — one request, and four —
which is what `requestLimit` being an init parameter is for: proving the sliced
path costs four minutes of audio rather than an hour of it.

## The live engine reports the whole transcript, every chunk

Nemotron's partial callback does not hand over the words it has just decoded.
It hands over `tokenizer.decode(accumulatedTokenIds)` — everything the stream
has said since it was loaded, again, on every chunk. Nothing in the callback
says where one utterance ended and the next began, and nothing in it ever
shrinks. Taken at face value it draws exactly two paragraphs, `You` and
`Them`, each growing for the length of the meeting, each re-decoded from the
whole token list every second or so. That is what it did until 21 August.

So the pause is noticed here, in `LiveTranscriptionCoordinator`: a side that
takes two seconds of audio without decoding a word has its block closed, and
the engine is asked to `finish()` — which is what clears the accumulation the
next block would otherwise be appended to.

Two seconds *of audio*, not of clock. A stopwatch reads a cold model as a
pause: the first chunks of a session can take longer to decode than they last,
and the first thing the wall-clock version of this did was cut `Привет!
Сегодня мы обсуждаем` in half. The audio is counted by the consumer that fed
it, and whether the engine decoded anything from that audio is read
synchronously, in the callback itself, through a lock — a hop onto the actor
would arrive after the audio it belongs to had already been counted as
silence.

Reports decoded before `finish()` landed are still on their way when it does,
and they still carry the closed text with them. `CumulativePartials` subtracts
what is already on screen, so a repeat says nothing and a repeat with two new
words says the two words — including the full stop the engine so often decodes
a beat after the pause it belongs to, which opens no block of its own.

## The words are in the code, not in a bundle

amanu speaks English and Russian, and both versions of every sentence sit side
by side in the source, in `localised(_:_:)`. That is not a preference. A
SwiftPM executable target has no resource bundle, and `swift run` and `swift
test` have no bundle at all — the same absence that keeps banners quiet, below.
`NSLocalizedString` there returns its own keys, so every test that finds a
control by the words on it would be reading identifiers instead of reading the
interface. And `.lproj` directories would need putting into the bundle by
something, which is a second assembler of the bundle beside `make app`.

Three things follow, and all three have already caught something.

The language is settled once, in `Run`, before the first window exists, and
never afterwards. A test process therefore never resolves it and is always in
English — which is what lets the suite look for *Keep the audio after
transcribing* on a Mac set to any language at all. Anything that reads the
language at some later moment is reading it after the windows were built —
and anything built *once* keeps whichever language was in force when something
first asked for it. A `static let` `DateFormatter` in `SetupForm` was right in
the running program only because nothing changes the language after startup;
in the suite, which does, it handed the second walk the first walk's language
and put *19 Aug* in a Russian window. It is built per use now. A thing that is
right by luck is worth less than a thing that is right by construction.

And nothing may decide anything by matching on the words. A `ChoiceCard`
coloured its own status green by testing whether the text began with
"answers", "downloaded", "key works" or "running"; translate the statuses and
every card in the window goes grey, with no test failing and nothing in the
code looking wrong. The caller knows what the machine answered and says so —
`report(_:good:)`. The same trap was in `SetupForm.outstanding`, which returned
the words the footer shows and was then asked whether it contained
`"parakeet"`.

And a sentence left in English hides behind a translated sentence beside it.
The walk that builds a window in both languages and compares the two used to
compare each label whole, and almost every label in these windows is several
independent phrases with a separator between them — a transcript is lines, a
provenance line is *who said so · how many turns*. `You` and `Them` over the
live transcript blocks survived the entire translation that way, sitting
beside a divider that had been translated; `manual` survived beside a turn
count that had been; a date survived beside a row title that had. Three of
those four were found the day the comparison started splitting on `\n` and on
` · ` and asking the question phrase by phrase. Compare the smallest thing
that is a sentence, not the largest thing that is a string.

## A capture restart is where echo cancellation and the wall clock get lost

The input device is reconfigured under a recording several times in an
ordinary meeting — a call app taking it, headphones connecting, AirPods
leaving an ear — and each time `MicRecorder` rebuilds its engine. Two things
have to survive that rebuild, and neither says anything when it doesn't.

**Voice processing has to be turned back on.** Restarting raw looks harmless
during a call, on the reasoning that the call app is cancelling echo anyway.
It is not: the call app cancels what it sends, and amanu taps the device
itself. A raw restart means the mic track writes down whatever the speakers
play, and on 20 August 2026 it did — the far end at −3 dB on our own track for
35 minutes, loud enough to be voted onto our side of the meeting by speaker
attribution. `.issues/rca-003`.

**The silence pad belongs after the attach, not before it.** Only the first
buffer of the new engine knows how long the route was actually down; starting
a device costs hundreds of milliseconds beyond the last buffer of the old one.
Padding before the attach leaves those out of the file, and every buffer after
the restart is written earlier than it happened — 0.37 s per restart, measured
against a Zoom cloud recording of the same call, and it never comes back.

**Our own change cannot be told from a dead engine, so do not try.** Enabling
the voice unit reconfigures the input device, which posts the notification the
restart listens for; restart on it and the restart starts the next one. But
dismissing a change because we probably caused it is worse, and it fails
silently: the same notification arrives when the engine has genuinely stopped,
and a dismissed one means the microphone is simply never rebuilt. That cost 43
seconds of a 67-second recording on the evening the window was added — engine
stopped, change dismissed as ours, mic silent until the next route change
happened along. What the window is for is buying time to ask the only question
that has an answer: five seconds after the attach, are buffers still arriving?

## The microphone has to be followed; it is not inherited

`AVAudioEngine` binds to the default input when it starts and stays there.
Change the default under a running engine and nothing at all happens — no
`AVAudioEngineConfigurationChange`, no error, the same microphone in the file
as before. So the mic track follows two things of its own accord: a listener on
`kAudioHardwarePropertyDefaultInputDevice`, and the session's 15-second tick
asking `MicRoute` whether the answer has changed. Remove either and choosing
another microphone mid-meeting leaves amanu recording the old one, silently,
for the rest of the call.

The device the *call app* is on is a different question from the default, and
the more correct one — Zoom can be on a microphone the system was never told
about. `kAudioProcessPropertyDevices` with an input scope answers it per
process. Two traps in the answer: a process doing duplex I/O lists its output
device there too (amanu's own capture reports the speakers next to the
microphone), and the device has to be bound explicitly with
`AUAudioUnit.setDeviceID` before any format is read, because with voice
processing the unit builds its aggregate around whatever it was pointed at.

**Setting a default device can silently do nothing.** `AudioObjectSetPropertyData`
on `kAudioHardwarePropertyDefaultInputDevice` returns `noErr` for a device
macOS will not make default — Zoom's hidden `ZoomAudioDevice` is one — and the
default stays where it was. Anything that switches devices, test harness
included, has to read the property back rather than trust the status. A whole
evening's conclusion about route changes was drawn from a switch that never
happened.

## Banners need a bundle

`UNUserNotificationCenter` has nothing to post under in a bare build, so
`swift run` and `swift test` are silent by construction rather than by
configuration. There is no environment variable to remember; the test in
`NativeAppTests` — *"A bare build has no bundle to post banners under"* — is
what keeps that true.

## Tests have a home of their own

Everything under `~` that amanu reads or writes — the config file, setup and
analytics state, the key drawer, the shared key files, the API keys in the
environment, the tools a login shell finds and the models they reach — goes
through `Home.current`. In a test process that is a sandbox, decided by the
code being linked into an `.xctest` bundle, so no test reads the developer's
config or reaches their `claude`. `SandboxTests` is the pin, in the same
spirit as the banner test.

A path built from `FileManager.default.homeDirectoryForCurrentUser`, or a key
read from `ProcessInfo.processInfo.environment`, walks straight past it and is
the bug coming back. So does `expandingTildeInPath`, which always means the
real home; `Home.current.expanding` means the current one.

A test that wants a particular config says so with `.freshHome(config:)` or
`withFreshHome`, which scope a directory of its own through a task-local.
Task-locals do not reach `Task.detached` or a dispatch queue: work that hops
onto one reads the shared sandbox instead — never the real home, but not the
test's config either. The interface language works the same way:
`InterfaceLanguage.$scoped`, or `.speaking(_:)`, and setting the process-wide
value from a test stops the run.

## A `CGColor` is a number, not a colour

`NSColor.separatorColor` is a rule that answers differently in light and dark;
`.cgColor` is the answer it gave once. A layer handed that answer keeps it, so
every border and hairline in the setup window vanished the first time someone
switched their Mac's appearance with the window already built — pale lines on
a white background. Worse, outside of drawing `.cgColor` resolves against the
*thread's* appearance rather than the view's, which for a view built before it
has a window is plain Aqua whatever the Mac is set to.

Anything that paints into a layer therefore conforms to `LayerTinted`: it
names its colours in `tintLayer()`, which is called through the view's own
appearance and again whenever that appearance changes. Setting
`layer.borderColor` anywhere else is the bug coming back.

## A stack view is not a window's content view

An `NSStackView` put in `window.contentView` with its
`translatesAutoresizingMaskIntoConstraints` turned off is sized by its own
constraints rather than by the window, and the two can then disagree. A
running copy of amanu was found with the status window's rows laid out for a
window 22 points shorter than the one they were in — the Live transcript
checkbox drawn across the Manage recordings button — and resizing the window
through the accessibility API moved nothing at all, which is how a frozen
layout tells you what it is. Nothing in the code asked for that; it is what
comes of the window's size and the layout engine each believing the other
follows.

The rows now hang from the top of a plain `NSView` content view, which
resizes with the window because that is all an ordinary view does, and the
constraint that stretches them to the bottom is `.defaultLow` so that a
window too short for its rows shows fewer of them rather than two in the
same place. Anything that measures the window's height measures the stack —
`fittingSize` on the content view answers for the container.

Two smaller things from the same window, both worth keeping in mind for any
`NSStackView`. A row with an empty label in it is still a row: the
transcription line, never spoken to on a Mac with nothing to transcribe, was
22 points of blank window from launch until the first transcription. And a
nested stack hugs its contents loosely, so spare height in the window went
*into* the last row rather than under it, and the checkbox floated out of
the corner it belongs in; a required vertical content hugging priority is
what stops it, relaxed only while the live transcript needs the room.

## A stack view is not a tab's content view either

`NSTabView` owns the frame of each tab's content view. Using an `NSStackView`
directly there made the Speakers pane add the tab's inset to its own position
on every layout: choosing another meeting moved it seven points right and six
points down, until it escaped the tab. Put a plain `NSView` in the tab and pin
the stack inside it. The regression test switches meetings repeatedly and
compares the pane's frame with the tab's content rectangle.

A truncating label can still enlarge the tab's minimum width: AppKit uses the
pane's fitting size, and the label's full intrinsic width participates in that
calculation. The opening excerpt's horizontal compression resistance must be
below `fittingSizeCompression`, so a long utterance can truncate during that
calculation too. Merely setting `byTruncatingTail` did not stop a meeting from
giving the window a minimum width of over eleven thousand points.

## Asking macOS what it has granted is not free

Measured inside the signed bundle on 19 August 2026, on an M-series Mac with
everything already granted: `SMAppService.mainApp.status` costs **14 ms** — it
is an XPC round trip to another daemon — `AVCaptureDevice.authorizationStatus`
about **6 ms**, and `EKEventStore.authorizationStatus` about **3 ms**. In a
bare build the first is free, because there is no bundle to register and
`LoginItem.status` answers `.unavailable` without asking anyone: the cost
exists only in the app, which is the only place it matters and the one place
`swift test` cannot see it.

They read like property accesses, so the setup form asked them the way you ask
a property: the access rows ask, the highlight asks again to find the row to
tint, and the footer asks twice more to say what is left and what its button
should say — twelve login-item lookups and twelve microphone lookups to redraw
once. Picking a summary card redraws twice, and spent a quarter of a second
inside the click doing nothing else.

`ThisTurn.answer` is the fix: the first ask in a turn of the main run loop goes
out to the system and the rest of that turn reads what it brought back. It is
safe precisely because changing any of these answers means going to System
Settings and coming back, which cannot happen without the run loop turning.
The exception is this program changing one itself — registering a login item,
or a TCC prompt it raised — and those call `ThisTurn.forget()`.

## Where a meeting may go is decided once

Naming and summarizing both show a model the transcript, and until September
2026 they decided separately where to send it: naming defaulted to `auto`
whatever the summary said, so somebody who chose Ollama so that nothing left
the Mac still had the `claude` CLI read every meeting to find names in it.
`MeetingEgress` now routes both, and anything new that hands a model meeting
content asks it first rather than calling `LLMBackend.available` with a
preference of its own. Nothing fails if you forget; the promise in the setup
window simply stops being true.

The `claude` CLI is asked as a completion, not as an agent — no tools, none of
the person's settings or hooks, no MCP servers, no session history — because
the transcript is whatever anybody on the call chose to say.
`LLMBackend.claudeArguments` is pinned by a test; a flag dropped from it is a
meeting that can talk a coding agent into reading the disk.

`codex exec` keeps the person's config.toml, where a custom provider lives,
and so also the MCP servers it defines — which the read-only sandbox does not
cover, since their tools run in the servers' own processes. `-c
mcp_servers={}` looks like the override and does nothing: codex merges a
table from the command line into the file's. Each server is switched off by
name instead (`LLMBackend.codexArguments`), and naming one the file does not
define stops codex outright, so the names are read from the file each time.

# What has never been verified

Not defects, and not oversights: places where the code is believed correct on
reasoning alone. Worth knowing before trusting any of them in front of someone.

- **The login item actually capturing system audio.** Registration works and
  `SMAppService.mainApp` reports enabled, but nobody has logged out and back in
  to watch the copy macOS starts record. The rest of the argument is sound and
  untested at the point where it matters.
- **The live transcript against a real call.** It works on synthesised speech
  and inside the app. It has never met a real far end with echo cancellation
  in front of it.
- **The items marked *by hand*** in
  `docs/testing/setup-window-manual-checklist.md` — a recording with real
  microphone speech and real playback, checked by ear; a permission denied and
  re-granted; a recordings folder moved into Documents.
- **The mic's retreats against a real device.** A call app on a microphone
  that refuses `setDeviceID`, or whose engine will not start, is now given up
  for the default and not asked again for a minute, then two, up to fifteen;
  a session whose voice processing will not start begins raw instead of
  failing. The decisions are tested; no real device has refused in front of
  them yet.
- **Silence for a gap, written off the tap callback.** Buffers after a gap go
  through `TrackWriter`'s queue until it catches up. Order and length are
  tested against a file; a real route change has not been listened to since.
- **Stopping on sleep.** The recording ends on `willSleepNotification`, which
  macOS delivers with a little time to spare. That the files and meta.json
  are complete when the lid opens again has not been checked on a real lid.
- **The hardened `claude` invocation against a real account.** The flags in
  `LLMBackend.claudeArguments` were checked against `claude --help` of 2.1.240,
  and the prompt now arrives on stdin with `--print` and `--system-prompt`
  rather than as the positional argument; no prompt has been run through it
  since. An older CLI that lacks one of the flags exits with "unknown option",
  which counts as a permanent failure and falls through to the next backend.
  Likewise "API Error: Connection error." as the CLI's offline answer is what
  it printed before, not something captured with this version offline.
- **The codex CLI with its MCP servers switched off.** The overrides were
  checked with `codex mcp list` against a `CODEX_HOME` of their own, codex
  0.145.0; no prompt has been run through `codex exec` with them, and the
  file's server names are found by a line reader, not a TOML parser.
- **The system tap has no restart.** Unlike the mic, a tap that dies mid-call
  is only reported — by the stall watchdog and the far-end warning — and never
  rebuilt. `AVAudioFile` cannot append, so a rebuilt tap would need a second
  file and meta.json to learn about segments.
- **The cloud transcription paths against the real services, since they
  moved onto `CloudHTTP`.** Every status, `Retry-After`, a poll through
  network failures, a resumed AssemblyAI job and cache reuse are tested
  against a `URLProtocol` stub. Nobody has yet watched AssemblyAI answer a
  resumed poll for a job submitted by an earlier attempt, or seen what the
  three services actually send with a 429. That a job asked about with a
  different key comes back 401 or 403, rather than 404, is an assumption:
  the job file records a digest of its key so that the question is rarely
  asked, and all three answers are taken for a job that is gone.
- **Model downloads resuming from Hugging Face.** The `Range` request, the
  206 and the fallback to a whole file on a 200 are tested against a stub;
  whether the CDN behind a `resolve/<revision>` redirect honours `Range` for
  both models has not been checked, and neither has two amanu processes
  meeting at the model's lock with a real download between them.
- **Whisper and GigaAM decoding on their own threads.** The move off the
  cooperative pool is tested with a stand-in for the native call; neither
  runtime has been run that way against a real model, cancellation included.

## Bold in the release notes cannot cross a line wrap

`scripts/notes-to-html.py` matches `**bold**` within a line, so a span whose
opening and closing markers landed on either side of a wrap survives into the
HTML as literal asterisks — in the window Sparkle shows every existing
installation. The script does not complain, because unmatched markers are not
an error to it, only text. Wrap the prose around the emphasis rather than
through it, and read the rendered HTML before shipping: `python3
scripts/notes-to-html.py docs/release-notes-vX.Y.Z.md | grep '\*'` should
print nothing.

## The SSH agent selected by the host can differ from ssh-add

The 0.4.16 release reached publication, then the legacy appcast push failed
with `Permission denied (publickey)`. The host configuration selected the
1Password agent, while `ssh-add -l` listed the working key in the system agent.
The same mismatch affected `reina`. Check `ssh -G` and verify the intended key
before changing anything; a command-scoped `-o IdentityAgent="$SSH_AUTH_SOCK"`
selected the existing system agent successfully. For the release script, pass
that option through both `GIT_SSH_COMMAND` and `RSYNC_RSH`. Do not rewrite global
SSH settings, replace keys, or rebuild an already published release to resume
the remaining push and deployment steps.

## Git diff abbreviations are not stable source fingerprints

The 0.4.17 publication check failed in a fresh ggml clone even though every
patched source byte matched the previously built release. Git chose eight
hex digits for object IDs instead of seven as the upstream object database
grew. Hash approved diffs with `--binary --full-index`; the expected digests
must use that same representation. Do not accept a newly observed digest
without comparing the actual source changes. The regression test varies
`core.abbrev` and still requires unrelated staged and unstaged edits to fail.

## Windows installer renaming must update Velopack's inventory

Renaming `Amanu-stable-Setup.exe` after `vpk pack` also requires updating the
Installer entry in `assets.stable.json` before computing `SHA256SUMS`.
The application updater reads `releases.stable.json`, which references the
versioned full package and is unaffected by installer naming.
`windows/scripts/Finalize-ReleaseArtifacts.ps1` now rewrites the inventory and
refuses missing referenced files; `Windows packaging metadata` tests this on Windows.
The original Windows 0.6.4 assets remain immutable. Its corrected installer
inventory was added as `assets.versioned.stable.json` with a separate checksum.
