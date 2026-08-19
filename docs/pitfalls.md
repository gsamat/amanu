# Things that will bite

Constraints that are not visible from the code that depends on them. Each one
was paid for once. Breaking any of them compiles, passes the tests, and fails
somewhere else — usually on somebody else's Mac, usually with a symptom that
points at the wrong thing.

This is not the user-facing list; that is **Gotchas** in the README, and it is
about running amanu rather than changing it.

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

## Banners need a bundle

`UNUserNotificationCenter` has nothing to post under in a bare build, so
`swift run` and `swift test` are silent by construction rather than by
configuration. There is no environment variable to remember; the test in
`NativeAppTests` — *"A bare build has no bundle to post banners under"* — is
what keeps that true.

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
