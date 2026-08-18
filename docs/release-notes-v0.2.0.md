amanu is a Mac application now. Drag it to Applications and open it; the first
launch walks through microphone, system audio and calendar access, picks a
transcription engine and a summary backend, and offers to start amanu at login.
There is nothing to do in Terminal.

## What changed since v0.1.0

- **An application, not a binary and a LaunchAgent.** v0.1.0 shipped a bare
  `amanu` executable that you copied into `~/.local/bin` and kept alive with a
  launchd job. That whole arrangement is gone. `Amanu.app` runs as an ordinary
  app with a Dock icon and a menu-bar item, registers itself at login through
  `SMAppService`, and closing its window leaves it recording.
- **The command line still works.** The app keeps `~/.local/bin/amanu` pointed
  at the executable inside the bundle, so `amanu record start`, `amanu process`
  and the rest still do what they did — and now they drive the same process
  that holds the microphone.
- **One archived file per recording.** When you keep the audio, a finished
  session settles into a single stereo `audio.m4a`: your microphone on the
  left, the other side on the right. A 75-second recording that was 20.6 MB of
  PCM comes out at 1.2 MB.
- **A live transcript while the meeting runs**, if you turn it on — streaming
  Parakeet in the status window, both sides labelled.
- **It updates itself.** Sparkle checks daily, verifies both Apple's signature
  and its own, and never interrupts a recording: a scheduled check is skipped
  while amanu is recording, and an update that arrives anyway waits until the
  recording has stopped before it installs.

## Requirements

Apple Silicon and macOS 15 or later. The application is signed with a Developer
ID certificate, uses the hardened runtime, and the disk image carries a stapled
Apple notarization ticket.

## If you installed v0.1.0

The old release had no uninstaller and this one does not remove it for you.
Three things to clean up by hand, in this order:

- Stop and remove the launchd job:
  `launchctl bootout gui/$UID/me.samat.amanu` and then delete
  `~/Library/LaunchAgents/me.samat.amanu.plist`.
- Delete the old binary at `~/.local/bin/amanu`. The app replaces that path
  with a symlink into the bundle on first launch and moves a real file it finds
  there aside with a dated name, so check for an `amanu.legacy-*` afterwards
  and delete that too.
- Nothing else needs touching. Your recordings in `~/Recordings` and your
  settings and keys in `~/.config/amanu` are read by the new version as they
  are.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.2.0-macos-arm64.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.2.0-macos-arm64.dmg`
- `xcrun stapler validate amanu-v0.2.0-macos-arm64.dmg`
