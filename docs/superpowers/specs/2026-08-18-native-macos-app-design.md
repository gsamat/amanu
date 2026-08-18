# Native macOS application

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

The primary architecture is accepted only if both Finder and login-item paths
pass. In that case Amanu is one normal application process and **Start at
login** registers `SMAppService.mainApp`. No embedded LaunchAgent is shipped.

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

A real Xcode application target owns `NSApplication`, the Dock and menu-bar
surfaces, all windows, permissions, the recording session, post-processing,
update coordination, and the local automation server. It is the only process
allowed to start audio capture or mutate an active session.

Its bundle supplies the canonical Info.plist, application icon, entitlements,
version numbers, usage descriptions, Sparkle configuration, and any service
metadata selected by the lifecycle spike. The linker-embedded bare-binary
Info.plist is retired.

Repeated launches activate the existing app instead of starting another
recorder. Window closure and Dock visibility are AppKit state, not process
lifetime controls. `NSApp.setActivationPolicy(.regular/.accessory)` continues
to implement the existing Dock preference without introducing a helper.

### AmanuCLI

A small signed executable is bundled for agents and automation. It is not a
second recorder and does not load the audio or transcription engines. Setup
installs `~/.local/bin/amanu` as a symlink to this bundled executable after
`Amanu.app` is in `/Applications`, so an application update also updates the
automation interface.

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

The app and CLI communicate through a Unix domain socket rather than assuming
a named Mach XPC service. A named `NSXPCListener` normally needs launchd
`MachServices` registration, which the preferred `SMAppService.mainApp`
lifecycle does not provide.

The socket is `~/Library/Application Support/Amanu/control.sock`. Its parent
directory is mode `0700`, the socket is mode `0600`, and the server verifies the
connecting peer's UID. Requests and replies carry a protocol version, request
identifier, operation, typed payload, and structured error. The wire
representation is JSON so it can be inspected during diagnosis, while the
Swift implementations use typed request and response values.

If the app is not running, the CLI locates the bundle by bundle identifier,
launches it through LaunchServices, and waits for the socket for a bounded
period. A missing bundle, refused launch, incompatible protocol, or timeout
returns a non-zero exit status and a JSON error. A stale socket is removed at
application startup after confirming that no server owns it.

A URL scheme may be added for Finder links such as opening a particular
recording. It is not the automation protocol because it cannot provide reliable
request/reply semantics. Named XPC or a separate XPC service remains out of
scope until a concrete requirement justifies it.

## Legacy migration

Migration runs only when no recording is active.

On first application launch Amanu inspects
`~/Library/LaunchAgents/me.samat.amanu.plist` and confirms that it is the known
legacy job before changing it. It stops the old job, registers the lifecycle
selected by the TCC spike, verifies that the new application instance is
healthy, and only then removes the old plist. A failure leaves a recoverable
state and explains how to retry in Setup.

The old `~/.local/bin/amanu` is atomically moved to an unused backup name
beginning `amanu.legacy-` and replaced with the symlink to bundled AmanuCLI. No
unknown executable is overwritten. The backup remains for the first native-app
release and is not started automatically.

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
https://samat.me/amanu/appcast.xml
```

The source file is tracked at `amanu/appcast.xml` in the `gsamat/samatme3`
repository. The site is served by nginx from `/var/www/samat` on `reina`; a
narrow deployment command syncs only the repository's `amanu/` directory to
`reina:/var/www/samat/amanu/`. This is necessary because the site's full deploy
uses `rsync --delete` and would remove an untracked server-only appcast.

The old GitHub Pages URL may continue to redirect to `samat.me`, but
`SUFeedURL` uses the canonical address directly.

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
   release-asset URL. Update and commit the tracked appcast in `samatme3`, but
   do not deploy it yet.
9. Publish the GitHub Release, atomically deploy the new `amanu/` directory to
   Reina, and verify the public feed, signature, and asset URL.

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
- socket permissions, peer identity, protocol versioning, timeouts, and stale
  endpoint recovery;
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

No native-app release is published until the lifecycle branch is selected by
the real TCC test and all acceptance checks for that branch pass.
