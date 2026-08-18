One disk image for every Mac. amanu is now a universal application: the same
download runs on Apple Silicon and on the Intel Macs that still take macOS 15.
Nothing changes for an existing install beyond the update itself.

## What changed since v0.2.0

- **The build is universal.** v0.2.0 was arm64 only, so an Intel Mac could not
  open it at all. This one carries both slices, Sparkle included.
- **On an Intel Mac, transcription is AssemblyAI's.** The local models —
  parakeet for the transcript, the streaming model for the live one — are Core
  ML packages compiled for the Neural Engine, and they are refused outright on
  Intel rather than falling back to a CPU that would be slower than the
  meeting. So there, the setup window offers the one engine that runs, the
  live-transcript switch is not shown at all, and `amanu doctor` says before a
  meeting what will happen after it — including that a machine with no
  AssemblyAI key records but cannot transcribe. Recording itself is unchanged.
- **Nothing changes on Apple Silicon.** Same engines, same defaults, same
  local-first behaviour. If you are on an M-series Mac this release is a
  no-op for you plus the fixes below.
- **Setup looks at the machine again when you reopen it.** Tool detection was
  cached for the life of the process, so following an **Install it** link and
  coming back was answered from before you installed anything.
- **The live transcript is finally documented**, and the settings reference is
  now pinned by a test — a setting that exists but appears in no window and no
  README is a setting nobody finds.

## Honest about what is untested

The universal build is measured, and so is the behaviour of each half: the
Intel slice was exercised under Rosetta, where it selects the cloud engine
while the Apple Silicon slice selects the local one. But **nobody has run
amanu on an actual Intel Mac.** Rosetta runs the Intel slice on Apple Silicon
hardware, which is the wrong half of the question, and the one thing that
would most repay a real test is system-audio capture — a part of amanu this
project has already been surprised by once. If you run it on an Intel Mac,
the interesting question is whether the far side of a call is recorded rather
than silence.

`docs/old-macs.md` in the repository keeps the measured and the expected in
separate columns.

## Requirements

macOS 15 or later, on Apple Silicon or Intel. The application is signed with a
Developer ID certificate, uses the hardened runtime, and the disk image
carries a stapled Apple notarization ticket.

## Verifying the download

The checksum is attached alongside the disk image.

- `shasum -a 256 -c amanu-v0.3.0-macos-universal.dmg.sha256`
- `spctl --assess --type open --context context:primary-signature -v amanu-v0.3.0-macos-universal.dmg`
- `xcrun stapler validate amanu-v0.3.0-macos-universal.dmg`
