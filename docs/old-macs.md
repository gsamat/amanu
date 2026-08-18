# Old Macs

What amanu does on a Mac that is not a recent Apple Silicon one, what sets each
limit, and — kept strictly separate — which of it has been measured and which is
only expected.

## Two limits, and they are not the same line

They get conflated constantly, so start here:

- **macOS 15 or later.** A software floor. It applies to every Mac.
- **Apple Silicon for local transcription.** A hardware floor. It applies to
  nothing else — recording, archiving, naming, summaries and the whole
  interface are architecture-blind.

macOS 15 runs on Intel Macs from 2018–2020. **The OS floor does not exclude
Intel by itself**, and an Intel Mac new enough to run macOS 15 is a machine
amanu can work on — with cloud transcription.

## What the macOS 15 floor is actually made of

Nothing, as far as anyone has established. That is worth knowing before someone
spends a day trying to lower it, and worth knowing before someone assumes it is
load-bearing.

It is declared in exactly two places, both amanu's own: `.macOS(.v15)` in
`Package.swift` and `LSMinimumSystemVersion 15.0` in
`Packaging/Amanu-Info.plist`. They agree with each other and with nothing else.

Everything underneath sits lower. Read out of the macOS 26.5 SDK headers rather
than from memory:

| What amanu calls | Its own availability |
|---|---|
| `AudioHardwareCreateProcessTap` — the system-audio tap | `macos(14.2)` |
| `EKEventStore.requestFullAccessToEvents` | `macos(14.0)` |
| `SMAppService` — the login item | `macos(13.0)` |

And the dependencies: FluidAudio declares `.macOS(.v14)`, Sparkle far lower.

So **no audit has ever found the API that requires 15.0.** It may not exist. If
somebody needs amanu on macOS 14, the work is an audit and two edited
declarations, not a port — but somebody has to do the audit, because "it
compiles" is not the same as "it runs on 14".

Worth saying plainly: amanu has only ever been run on macOS 26. The declared
floor of 15.0 has never been exercised by anyone, on any machine.

## Intel

### It builds, and the build is universal

**Measured.** `swift build -c release --arch arm64 --arch x86_64` succeeds. Two
`--arch` flags move the product to `.build/apple/Products/Release/amanu`, and
`lipo -archs` reports `x86_64 arm64`. Sparkle's xcframework already ships a
`macos-arm64_x86_64` slice, so the framework inside the bundle is universal too
— its binary was checked, not just the directory name. `make app` fails if a
slice is missing rather than shipping half an application.

### Local transcription is impossible there, and not because it is slow

**Measured, and this is the part that surprises people.** FluidAudio refuses
before Core ML is ever involved: `guard SystemInfo.isAppleSilicon else { throw
ASRError.unsupportedPlatform(...) }` in `AsrModels`, and the same guard in the
streaming manager for the live model. `SystemInfo.isAppleSilicon` is
`#if arch(arm64)` — compile-time, per slice.

That makes it a **library refusal, not a capability probe**. Consequences worth
spelling out, because each one has been guessed wrong at least once:

- There is no CPU fallback, so there is nothing to be slow with. It does not
  run badly; it does not run.
- A powerful discretionary GPU in a 2019 Mac Pro changes nothing. Nothing is
  asked of the GPU.
- It is decided when the slice is compiled, not when the Mac is inspected. The
  x86_64 slice has the answer baked in.

So on Intel: **AssemblyAI or nothing.** A key is not a preference there, it is
the feature.

### What the program does about it

One `Platform.supportsLocalModels` — compile-time, per slice — is asked once,
and everything that would otherwise reach for a local model asks it:

- the queue picks the cloud engine and says so in the log;
- `doctor` reports what will actually run, including the case worth naming out
  loud: local transcription needs Apple Silicon and there is no AssemblyAI key;
- Setup offers one engine card instead of three;
- the live-transcript switch and its setting are not offered at all, and the
  status window's live section is hidden.

The engine matrix is a pure function with tests for both halves — necessarily,
since a test run only ever happens on one of them.

## Measured, and not measured

Be strict about this. The distinction is the only reason the document is worth
anything.

**Measured.** The universal build, above. And the x86_64 slice running
correctly: under Rosetta, `arch -x86_64 …/Amanu doctor` reports the cloud
engine while `arch -arm64` with the same configuration reports parakeet. That
exercises every branch of the platform split for real.

**Not measured: amanu has never run on an Intel Mac.** Nobody has one here.
Two things follow.

- **Rosetta does not close this gap.** It runs the x86_64 slice on Apple
  Silicon hardware, which is the wrong half of the question. It tests the code
  path, not the machine.
- **The system-audio tap on Intel hardware is an expectation, not a result.**
  Nothing in that path is architecture-dependent and process taps are an OS
  feature rather than a chip feature, so identical behaviour is what one would
  predict. This project has been wrong about that tap before:
  `.issues/rca-002-system-tap-silent-outside-launchagent.md` is an entire
  investigation into it returning digital silence in a situation nobody had
  thought to distinguish. Until somebody records a meeting on an Intel Mac and
  finds a far-end track with something on it, this stays in the *expected*
  column.

Do not claim Intel support in release notes until that has happened. "It
compiles and the platform split is tested" is true and is not the same claim.

## The update feed has no idea about architecture

**Reasoned, and it is a trap for later.** The appcast advertises one enclosure
to everyone; Sparkle filters on version, not on slice. So the moment an Intel
Mac is running amanu, **every subsequent release must stay universal**. Ship one
arm64-only build after that and the feed cheerfully offers it to an Intel
machine that cannot execute it.

v0.2.0 shipped arm64-only — `lipo -archs` on that bundle says `arm64`, and its
release notes say Apple Silicon, which was accurate. From the first universal
release onward, dropping back is a one-way mistake. If a release ever genuinely
must be single-arch, the feed needs per-architecture filtering first, and that
is a change to `scripts/release.sh` and to the appcast, not a judgement call at
release time.

## If you want to go lower still

- **macOS 14.** Plausibly free. Audit what actually needs 15, change the two
  declarations, and test on a real 14 machine. `AudioHardwareCreateProcessTap`
  at 14.2 becomes the real floor, so 14.0 and 14.1 are out.
- **macOS 13.** Costs the system-audio tap (14.2) and full calendar access
  (14.0). The tap is half the product — a meeting recorder that records only
  your own voice. Not worth it.
- **Local transcription on Intel.** Needs a different ASR engine. FluidAudio
  will not serve it at any macOS version, and the guard is not something to
  patch out: it is there because the models are Apple-Silicon Core ML packages.
