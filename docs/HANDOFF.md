# Where amanu stands, and what is left

Rewritten 19 August 2026, the night amanu shipped as an application. The
previous version of this file listed eight things to do; seven of them are
under *Done* below, and the eighth was dropped on purpose.

## The short version

amanu is a released macOS application. `Amanu.app` records both sides of a
meeting, transcribes them, names the speakers and writes a summary; the audio
is archived as one stereo M4A or discarded; there is an optional live
transcript in the status window; and it updates itself through Sparkle without
interrupting a recording to do it.

**v0.2.0 is public**: a signed, notarized, stapled disk image at
[the release](https://github.com/gsamat/amanu/releases/tag/v0.2.0), with the
feed at `https://samat.me/amanu/appcast.xml`. The update path was not reasoned
about — it was run. The installed build 86 found build 93 through the live
feed, verified it, downloaded it, installed it and relaunched itself.

## The state of this machine

- `/Applications/Amanu.app` is 0.2.0 build 93, and it arrived there **through
  Sparkle** rather than by hand. Registered at login, one copy running.
- The microphone grant survived both the Sparkle re-signing and the update.
  That is the expected behaviour — the designated requirement is the identity,
  not the hash — and it is now measured rather than assumed.
- `~/.local/bin/amanu` is a symlink into the bundle and still resolves after
  the update. Sparkle is found through `@executable_path/../Frameworks`, which
  survives being reached through that symlink; it was checked.
- Keys: `~/.config/amanu/keys/` for the app. The Sparkle **private** key is
  `~/.appstoreconnect/amanu-sparkle-ed25519.key`, 0600, outside git, alongside
  the other distribution material; its public half is in the bundle's
  Info.plist. Lose the private key and no existing installation can ever be
  updated again — it is the one secret here with no recovery path.
- `.env.asc` in the repository root (gitignored) carries the App Store Connect
  ids `notarytool` needs. Same account as the iOS projects.
- Test recordings from 18 August are still in `~/Recordings`; all synthesised
  speech, all deletable.

## Done since the last handoff

- **Released.** `scripts/release.sh` is one fail-closed command: tests, bundle,
  signature and designated requirement, disk image, notarization with the
  ticket stapled and Gatekeeper asked for its own opinion, a *draft* GitHub
  release, the EdDSA-signed appcast — and only then the publish and the deploy
  to reina. Nothing is public before the last stage, and the feed goes out
  after the download it points at is already reachable.
- **Sparkle**, embedded and signed by `make app` rather than by an Xcode phase.
  The rule that is amanu's rather than Sparkle's lives in `UpdateGate`, which
  is testable without a bundle: a scheduled check is skipped while recording,
  and an install offered anyway is held and run when the recording stops.
- **`amanu process` re-transcribes from the stereo archive**, through the same
  extraction the recordings window uses, with `--again` as the command-line
  twin of **Re-transcribe**. A session whose audio was discarded is refused
  with a reason instead of reporting `transcript: pending` and doing nothing.
- **Speaker naming worked out.** It named nothing because `SpeakerAttribution`
  split one voice into two labels: the far end leaks into the room mic, so a
  minority of every person's utterances read as mic-loud, and one diarized
  voice arrived as `me X` and `them Y`. The model had been answering correctly
  all along and the confidence gate was throwing the answers away. Voices are
  now settled onto one side by majority over the whole meeting. Measured across
  twelve real sessions; on `2026.08.18-1502` naming goes from `named 0 of 4` to
  `named 2 of 2`. **Sessions already on disk keep their old labels** —
  re-transcribe them if you care.
- **The manual checklist was run end to end for the first time**, and found a
  real defect: the Summaries switch had no target and no action. It slid under
  the finger, wrote nothing, disabled nothing, and every meeting was summarised
  by a model the person had just switched off. Fixed, with a test that asks the
  only question separating a switch that moves from a switch that does
  something. The checklist itself was wrong in half a dozen places and has been
  corrected against the window it describes.
- **The spec matches the code**, and the README no longer promises two things
  the code stopped doing.

## Dropped on purpose

Two items from the old list are gone by Samat's decision, not by oversight.
Don't quietly reinstate them:

- **The login-item TCC test.** Registration works and `SMAppService.mainApp`
  reports enabled; nobody has logged out and back in to watch the copy macOS
  starts capture system audio. That part rests on reasoning.
- **Live transcript on a real Zoom call.** It works on synthesised speech and
  in the app; it has never met a real far end with echo cancellation in front
  of it.

## What is left

Small, and mostly things that need a person rather than a session.

- **The parts of the checklist marked *by hand*** in
  `docs/testing/setup-window-manual-checklist.md`: a recording with real
  microphone speech and real Mac playback with the two channels checked by ear,
  a permission denied and re-granted, the **Install it** link seen in the state
  where a CLI is missing, and a recordings folder moved into Documents.
- **The system-audio tone after the update.** The Setup row still reads *heard
  the tone · Aug 19* from before the Sparkle work. The microphone grant
  demonstrably survived the update and system audio uses the same mechanism,
  but nobody has pressed **Test again** since. It is one button and one beep,
  and it wasn't pressed at one in the morning.
- **The recordings window's Finish processing** has the gap `amanu process`
  used to have: on a settled session with no transcript it does nothing.
  **Re-transcribe** covers the case, so this is a tidy-up, not a hole.
- **Nothing coordinates the CLI with the running app** over a session folder.
  If `amanu process` and the app's own queue reach for the same recording, both
  will transcribe it. The app only scans at launch or on request, so the window
  is small — and closing it properly is what the cancelled socket would have
  been for. It is not worth the socket.

## Things that will bite

- **App Nap.** The app holds a `userInitiated` activity for its whole life and
  a sleep-blocking one while recording. Remove either and the symptoms are
  confusing: IPC that answers seconds late, timers that drift, a request obeyed
  after the caller gave up.
- **`Bundle.main` and the symlink.** The CLI reaches the executable through
  `~/.local/bin/amanu`, and Foundation answers for the path it was invoked
  through. `Runtime.appBundle` resolves the link first; anything asking "am I
  bundled" must go through it.
- **TCC and the code signature.** Grants are keyed to the Developer ID
  signature and `me.samat.amanu`. Changing either re-prompts for everything —
  it happened once, on 18 August, when signing moved to Developer ID.
- **Nested code is signed innermost first.** `codesign` seals what it finds, so
  Sparkle's framework signed after the app containing it silently invalidates
  the app — and the failure appears as a Gatekeeper rejection on somebody
  else's Mac, not on this one.
- **`grep -q` in a pipeline under `set -o pipefail`** turns a passing check into
  a failing one: grep closes the pipe on its first match and the writer takes a
  SIGPIPE. The release script hit exactly this, and now captures first.
- **`gh` picks a remote by itself.** This checkout has an `upstream` pointing at
  the project amanu was forked from, and the first release attempt tried to
  publish there. Every `gh` call names `--repo` now.
- **Nothing writes to shared key files.** If a feature needs a key, put it in
  `Config.keysDir`.
- **`swift test` needs `AMANU_NO_NOTIFY=1`**, or the suite posts banners.

## How to work on it

```sh
make app                                 # build + sign .build/Amanu.app
cp -R .build/Amanu.app /Applications/    # replace the installed copy
AMANU_NO_NOTIFY=1 swift test             # 135 tests
make release-dry                         # the whole release except publishing
make release                             # and publishing
```

Bump `VERSION` in the Makefile before a release; the build number comes from
`git rev-list --count HEAD` and only ever goes up. The release refuses to run
from a dirty tree, and refuses to replace a release that is already published.

A recording made by hand is still the only way to test the audio paths. The
tests cover everything else.
