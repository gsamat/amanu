# Native macOS application

> **Status, 19 August 2026.** Built and running. The decision gate below was
> measured and passed, and the application, its login item, the migration off
> the LaunchAgent and the agent interface all exist. Two things were built
> differently from the plan below, deliberately, and the sections concerned say
> so: the bundle is assembled by `make app` around the SwiftPM binary rather
> than by an Xcode target, and the agent interface is the distributed
> notification doorbell plus a symlinked CLI, and the socket the plan called
> for is not being built.
>
> **Packaging and updates** has since been built too, and shipped as v0.2.0:
> a notarized, stapled disk image, Sparkle behind a signed appcast, and
> `scripts/release.sh` doing the whole thing fail-closed. `docs/releasing.md`
> is the runbook.

## Goal

Turn amanu from a signed command-line binary that happens to open AppKit
windows into a conventional macOS application. A person installs `Amanu.app`
by dragging it to `/Applications`, completes setup in the app, and never needs
Terminal. Closing the status window leaves Amanu running in the Dock and menu
bar so automatic recording continues.

The change must preserve the system-audio path that has been proven on real
meetings, existing recordings and configuration, internal Claude Code and
Codex integrations, and a narrow automation interface for software agents.

The first native application supports Apple Silicon and macOS 15 or later. It
uses the existing feather artwork for its application icon.

## Non-goals

- Intel support.
- Replacing the compact status window with a recordings library.
- Splitting recording into a permanent helper process unless a live TCC test
  proves that the main application cannot capture system audio reliably.
- Removing Claude Code, Codex, Ollama, or API-key backends.
- Moving `~/Recordings` or `~/.config/amanu`.
- Building a custom updater or hosting release binaries on `samat.me`.

## User experience

`Amanu.app` is a regular Dock application with a menu-bar item. Its main window
remains the deliberately compact recording status window. **Manage
Recordings**, **Settings**, and **Setup** open as separate windows.

Closing the status window does not terminate Amanu. Clicking the Dock icon
shows or hides it using the current toggle behaviour. `Command-Q` and **Quit
Amanu** perform a real, graceful termination after finalizing any live
recording. A later manual launch or the next login starts the application
again.

The Setup window retains **Start at login**. All permission checks, diagnostics,
installation, processing, and re-transcription actions are available in the
graphical interface. The app does not expose the old human-facing commands
`run`, `install`, `doctor`, `setup`, `sessions`, or `process`.

Claude Code, Codex, and Ollama remain internal backends. Amanu may start their
executables without opening Terminal, just as it does today. Setup describes
the services by product name and availability rather than asking the person to
run commands.

## Architecture decision gate: system-audio attribution

The existing RCA demonstrates that a bare binary launched from Terminal is
attributed to the terminal as its responsible process and receives correctly
clocked but silent Core Audio tap buffers. It also demonstrates that the bare
binary captures system audio when `launchd` owns the process. It does not test
a correctly signed application bundle launched by Finder, LaunchServices, or
`SMAppService.mainApp`.

The implementation therefore begins with a small empirical spike before the
application is reorganized around either lifecycle:

1. Build a minimal Developer ID-signed `Amanu.app` with bundle identifier
   `me.samat.amanu`, the required usage descriptions, hardened runtime, and the
   audio-input entitlement.
2. Stop the legacy external LaunchAgent so it cannot mask the result.
3. Reset only Amanu's system-audio-capture TCC decision.
4. Launch the application through Finder or LaunchServices, run the existing
   Setup tone test, and verify that the captured stream contains non-zero
   samples.
5. Register `SMAppService.mainApp`, start the application through a fresh login,
   and repeat the tone and non-zero-stream test.
6. Record a short real two-sided sample and verify both microphone and system
   tracks.

**Measured 18 August 2026.** `spike/tcc-bundle` — a signed bundle with its own
identifier, which plays a 440 Hz tone into a global tap and counts what comes
back — reported 479 232 samples, 100% non-zero, peak −12 dB, when launched
through LaunchServices, and named itself as its own responsible process. A
second run while a separate process spoke confirmed the tap hears other
applications and not merely its own output. The same was then measured on
amanu itself: a test recording's far-end track came back at −17.6 dBFS.

The Finder path therefore passes and the primary architecture is accepted:
Amanu is one normal application process, **Start at login** registers
`SMAppService.mainApp`, and no LaunchAgent is shipped. The login-item path —
the same measurement after a real logout and login — has not been run yet; it
is the one open item from this gate.

If either path produces digital silence, the measured fallback is an embedded
LaunchAgent registered with `SMAppService.agent(plistName:)`. It launches the
same signed executable inside `Amanu.app`; recording and UI still live in one
process. The fallback is selected because of the new measurement, not because
the old bare-binary RCA is generalized beyond its evidence.

The rest of the design, including the agent CLI transport, does not depend on
which branch passes.

## Components

### AmanuCore

Recording, call detection, session storage, transcription, speaker naming,
summaries, configuration, and post-processing become code that does not depend
on ArgumentParser or a particular application launch mechanism. Existing unit
tests continue to exercise this layer.

### AmanuApp

**Built, without an Xcode target.** The package already builds and tests with
SwiftPM, and an application is a directory with a plist in it: `make app`
assembles `.build/Amanu.app` around the same binary and signs it Developer ID
with the hardened runtime and the audio-input entitlement. A second build
system would have to be kept in step with the first and buys nothing here.

The bundle supplies the canonical Info.plist (`Packaging/Amanu-Info.plist`),
entitlements, version numbers, usage descriptions and the icon, which
`scripts/make-icon.swift` draws from the same feather the menu bar uses. The
linker-embedded Info.plist stays for now: the bare binary is still built by
`make install`, and a machine mid-migration runs it.

The application owns `NSApplication`, the Dock and menu-bar surfaces, all
windows, permissions, the recording session and post-processing. It is the only
process allowed to start audio capture or mutate an active session. Two things
a bundle needs that the daemon did not: a second launch hands over to the copy
already running rather than becoming a second recorder (`SingleInstance`), and
the process holds a `userInitiated` activity for its whole life, because App
Nap throttles a background application and a recorder is in the background by
definition.

Repeated launches activate the existing app instead of starting another
recorder. Window closure and Dock visibility are AppKit state, not process
lifetime controls. `NSApp.setActivationPolicy(.regular/.accessory)` continues
to implement the existing Dock preference without introducing a helper.

### AmanuCLI

**Built as the same executable, not a second one.** `~/.local/bin/amanu` is a
symlink to the binary inside the bundle, so an application update updates the
automation interface, and the CLI and the app are provably the same signed
program. `Runtime.appBundle` resolves that symlink before deciding whether it
is running as an application — Foundation otherwise answers for the path it was
invoked through, which is a plain directory, and the CLI would install a
LaunchAgent from inside the app.

The supported surface is intentionally narrow and machine-readable:

```text
amanu status --json
amanu sessions --json
amanu record start|stop|pause|resume
amanu process <session>
amanu open <session>
```

Finished recordings remain directly readable in `~/Recordings`; agents do not
need the CLI merely to read `meta.json`, `transcript.json`, `transcript.md`, or
`summary.md`.

The CLI never creates a recorder, requests TCC permission, installs a service,
or runs Setup. Control and processing commands are sent to the already running
application. This prevents a terminal-launched child from reintroducing the
responsible-process failure.

## Local automation transport

A distributed notification carrying a request id, answered by an
acknowledgement the caller waits for. `SetupRequest` opens the window,
`RecordRequest` starts and stops a recording, `SingleInstance` hands a second
launch over to the copy already running. Both sides are the same signed
executable, the notifications never leave this Mac, and the whole thing is
about a hundred lines.

This is the interface. An earlier draft of this document specified a Unix
domain socket with a versioned protocol, typed payloads and peer-UID checks;
that is a day of work and a suite of tests for something scripts on one machine
already have, and it is not being built. Anyone reading this later and
reaching for it should have a concrete requirement in hand first, and should
know they are reversing a decision rather than completing a plan.

Two rules it turned out to need, both learned the hard way: acknowledge before
acting, because starting a recording takes longer than a caller will wait and
being slow is not the same as being absent; and hold a process activity, or App
Nap delays delivery past any reasonable timeout.

A URL scheme may still be added for Finder links such as opening a particular
recording.

## Legacy migration

Migration runs only when no recording is active.

On first application launch Amanu inspects
`~/Library/LaunchAgents/me.samat.amanu.plist` and confirms that it is the known
legacy job before changing it. It stops the old job, registers the lifecycle
selected by the TCC spike, verifies that the new application instance is
healthy, and only then removes the old plist. A failure leaves a recoverable
state and explains how to retry in Setup.

The old `~/.local/bin/amanu` is moved to an unused backup name beginning
`amanu.legacy-` — numbered if the dated name is already taken — and replaced
with the symlink into the bundle. An existing *symlink* is simply replaced: it
is a pointer, not anybody's file. No unknown executable is overwritten, and the
backup is not started automatically.

Existing configuration, credentials, session folders, queue state, and derived
files remain in place. The application uses the same bundle identifier and
Developer ID identity, but Setup does not assume old TCC grants survive the move
into an application bundle. It verifies microphone, system audio, calendar,
and startup state and asks again where macOS requires it.

`Finish processing.command` is no longer created for new sessions. Processing
is available from Manage Recordings and AmanuCLI. Existing scripts remain
harmless and can continue to call the compatibility CLI during the migration
period.

## Failure handling

- A denied or disabled login item does not prevent manual use. Setup shows the
  current `SMAppService` status and opens the relevant System Settings page.
- Setup is incomplete while its deliberate tone produces digital silence. It
  offers retry and permission repair rather than accepting an API-level
  success with zero samples.
- Quit, migration, relaunch, and update operations defer while recording. A
  termination request finalizes audio and metadata before the process exits.
- The updater never replaces the application during recording or session
  settlement.
- An app launched from its read-only DMG asks to be moved to `/Applications`
  before enabling login launch or updates.
- The CLI reports unavailable app, launch timeout, protocol mismatch,
  conflicting operation, and invalid session as distinct structured errors.
- Only the app process settles or reprocesses a session. Concurrent CLI callers
  receive the current operation state instead of starting duplicate work.

## Packaging and updates

The release is an Apple Silicon `Amanu.app` for macOS 15 or later. It is signed
with `Developer ID Application: Samat Galimov (47B25GR8V2)`, uses hardened
runtime, includes the required entitlements, and is notarized. The distributed
DMG is signed, notarized, stapled, and contains `Amanu.app` plus an
`/Applications` shortcut.

The application has an incrementing `CFBundleVersion` and a semantic
`CFBundleShortVersionString`. Sparkle provides the native update UI and verifies
both Apple code signing and its own EdDSA signature. The EdDSA public key is in
the app; its private key lives outside git.

The same notarized DMG is attached to the public GitHub Release and referenced
by the Sparkle appcast. Release binaries remain on GitHub rather than consuming
bandwidth from the personal website.

The canonical feed URL is:

```text
https://amanu.me/appcast.xml
```

The source file is tracked at `landing/appcast.xml` in this repository and is
served by nginx from `/var/www/amanu` on `reina`. Builds released before this
move still request `https://samat.me/amanu/appcast.xml`, so the release flow
also keeps a byte-identical compatibility copy in `gsamat/samatme3` and at the
old public URL. New bundles use the canonical `amanu.me` address directly.

## Release flow

One fail-closed release command performs these stages in order:

1. Run unit, integration, and UI tests.
2. Archive the release application.
3. Sign the app and nested code with Developer ID and hardened runtime.
4. Verify signatures and designated requirements.
5. Build and sign the DMG.
6. Submit it to Apple Notary Service, require `Accepted`, staple the ticket,
   and require Gatekeeper acceptance.
7. Create a draft GitHub Release and upload the DMG and checksum.
8. Generate and EdDSA-sign the Sparkle appcast entry using the final stable
   release-asset URL. Update `landing/appcast.xml`, but do not deploy it yet.
9. Publish the GitHub Release; commit and deploy the landing plus canonical
   appcast to Reina; commit and deploy its compatibility copy to the old URL;
   then verify both public feeds, the signature, and the asset URL.

A failed stage prevents every later stage. Before step 9, nothing new is
public. If the final appcast deployment fails after the GitHub Release becomes
public, clients continue seeing the previous feed rather than a partial file;
the release remains available for manual download and deployment can be safely
retried. Release notes identify the architecture, minimum macOS version,
checksum, and migration behaviour.

## Verification

Automated coverage includes:

- existing AmanuCore behaviour;
- application lifecycle and closing the window without quitting;
- single-instance activation;
- legacy plist recognition and fail-safe migration;
- replacement of only the known legacy CLI;
- the doorbell: a request that is answered, a request nobody answers, and a
  malformed one;
- every agent CLI request and structured response;
- serialized session processing;
- update deferral during recording;
- Setup, Settings, status, and recordings-window routing.

Real-Mac acceptance includes:

- the TCC lifecycle spike described above;
- first launch from the DMG and after copying to `/Applications`;
- microphone, system-audio tone, and calendar permission flows;
- a two-sided recording with non-zero independent tracks;
- window close/reopen, Dock policy changes, quit, and login launch;
- migration from the released bare-binary installation;
- update from the previous native version through a test appcast;
- download of the published GitHub asset followed by checksum, `codesign`,
  `stapler`, and Gatekeeper verification;
- retrieval of the final signed appcast from `samat.me` and successful Sparkle
  update discovery.

**Where this stands.** The lifecycle branch is selected — the Finder path was
measured and passed. Covered by tests today: window-server arguments, the
start-at-login policy for both bundled and unbundled copies, recognising the
legacy plist as ours, the CLI relink being repeatable and never eating a
binary, and the notification carrying its session. Covered by real recordings:
system audio through the application, the stereo archive, the live model.
Not yet done: the login-item measurement after a real logout, and every
acceptance check that involves a DMG, notarization or an update.
