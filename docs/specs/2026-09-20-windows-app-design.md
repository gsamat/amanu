# Native Windows application

> **Status, 20 September 2026.** Approved and in implementation. The legal
> publisher will be selected before a public release. Beta CI supports an
> optional development certificate; without that secret, builds are explicitly
> marked unsigned and are not represented as production-signed.

## Goal

Ship Amanu as a native Windows 11 application with the same product contract
as the macOS application: automatic and manual meeting recording, separate
microphone and call tracks, crash recovery, live and post-meeting
transcription, speaker attribution, summaries, a recordings browser, setup,
settings, a tray surface, and safe automatic updates.

Functional parity matters more than sharing platform implementation. The
session directory and its artifacts are the cross-platform contract. Nobody
is expected to move configuration between macOS and Windows machines.

Calendar integration is deliberately excluded from the Windows application.
It is not a deferred beta item.

## Supported systems

The first beta targets Windows 11 25H2 on x64. The code and package layout
must remain architecture-neutral so an ARM64 build can follow without a
redesign. Windows 10 is not supported.

## Product shape

Amanu is a per-user desktop application. It has a normal taskbar window and a
system-tray surface. Closing the window keeps automatic recording running;
Quit stops the process after settling any active recording. Start at login is
on by default after setup and remains controllable in Settings and Windows
Startup Apps.

The initial Windows UI is implemented in C# as a native WPF shell on .NET 10;
Windows App SDK/Win32 adapters are introduced only where they provide a
platform capability rather than as an extra runtime requirement.
Platform-independent policy and session code lives in a plain .NET library.
WASAPI and other Win32 adapters stay behind narrow interfaces so they can be
tested with recorded observations and replaced independently.

## Recording

The preferred capture is WASAPI application loopback for the selected call
process and its child processes. The microphone is captured independently.
Both sources are written as crash-tolerant PCM while the meeting is live and
settled into the same retained stereo archive contract as macOS.

Automatic recording watches microphone capture sessions owned by configured
call process families. It keeps the existing start delay, stop delay, minimum
duration, two-track silence stop, maximum duration, and manual-stop
suppression rules. Browser process trees may contain unrelated tabs; Setup
and beta notes disclose that Windows cannot always isolate one browser tab.

If process loopback is unavailable or fails, Amanu must report the failure and
offer an explicit whole-system fallback. It must not silently broaden a
selected-app recording.

## Processing

Cloud transcription, speaker naming, and summary backends retain their macOS
contracts. Local engines use Windows-native runtimes:

- Whisper and GigaAM use native CPU/GPU-capable builds.
- Parakeet and live transcription use ONNX Runtime with DirectML where a
  compatible model exists, with a measured CPU fallback when practical.
- An unavailable local engine is shown as unavailable; it never silently
  uploads audio.

The beta may stage these engines, but every unavailable parity item must be
visible in Setup and release notes rather than represented as complete.

## Files and configuration

Session folders keep the macOS artifact names and meanings: `meta.json`, live
PCM tracks, `audio.m4a`, `transcript.json`, `transcript.md`, `speakers.json`,
`summary.md`, and processing logs.

Configuration lives under `%LOCALAPPDATA%\Amanu`. Recordings default to
`Documents\Amanu Recordings`. Secrets live in Windows Credential Manager or a
DPAPI-protected store. Shared setting names keep their existing semantics;
platform presentation and process identifiers use Windows-specific fields.
The command hook is stored as an executable plus an argument array rather than
as a shell string.

## Packaging, updates, and signing

Velopack produces a per-user Setup executable, full and delta update packages,
and a beta channel. The application never applies an update while recording
or settling a session. Release CI signs the executable, native libraries,
installer, and update artifacts before publication.

Beta builds use a development certificate and carry a visible Beta label.
Public releases use Azure Artifact Signing Public Trust. The legal entity and
certificate profile are intentionally left open until the publisher is
selected.

## Verification gates

A beta is publishable only after all of these pass on a clean Windows 11 25H2
x64 machine:

1. Setup starts, requests or diagnoses microphone access, and registers start
   at login.
2. Zoom, Teams, Telegram, and a Chromium meeting trigger automatic recording.
3. Microphone and call playback appear on separate non-silent tracks.
4. Headset and default-device changes preserve the session timeline.
5. Killing Amanu during recording leaves recoverable PCM and the next launch
   adopts the session.
6. A cloud transcript and summary complete and are visible in Recordings.
7. Closing the window leaves the tray recorder alive; Quit settles safely.
8. A beta update waits for recording to end, installs, and preserves settings
   and sessions.
9. The installer and installed binaries have valid signatures. The temporary
   beta trust instructions are explicit until Azure Artifact Signing replaces
   the development certificate.
