# Windows beta.17 candidate — 30 September 2026

Candidate: **0.6.0-beta.17**, application source
`e19bf7b1163a082657d6fc7dec2dbe35d626fa57`, branch
`codex/windows-beta14-candidate`.
[Signed Windows build](https://github.com/gsamat/amanu/actions/runs/36766785101).
The installer is installed on the tester's Windows computer. The candidate has
not been merged into master. No GitHub Release, production deployment or public
update-feed publication was made.
Master `d676f7f` was merged into the candidate branch for review. The Windows
application, tests, build scripts and workflow remain byte-identical to the
signed build's source; later integration/report commits do not change its payload.

## Consolidation and fixes

The remote branches and open pull requests were inspected. The Windows testing
branch already contained the Windows work from the signing branch. No additional
Windows app commits were missing from `analytics-delivery`, `homebrew-cask`,
`signing-smoke` or `stable-localvqe-source-digests`. Master's original manual
Windows workflow is already covered by this candidate's signed workflow.
The candidate combines the existing Windows app and beta.13 fixes with:

- Claude Code discovery inside the Microsoft Store Claude Desktop package.
- A viewer opened by `on_stop` no longer holds up the processing queue; the hook
  still runs once per session.
- Persistent local Nemotron streaming recognition with independent child
  decoders for microphone and system audio. Native failure cannot terminate
  the durable recorder.
- Live recognition interrupts a previous local batch pass; the batch pass
  resumes after Stop without consuming a processing attempt.
- Live workers use `AboveNormal` priority with a bounded thread budget;
  background final transcription uses `Idle` priority.
- The live panel appears immediately and shows idle, loading, waiting and
  paused states. A late result does not reopen the panel after Live is disabled.
- The portable final-transcription CLI initializes its CPU modules before
  ordinary and batch model loading. The build checks this startup path.

## Windows validation

Host: Windows 11 build 26200, Intel Core i5-10310U, eight logical processors,
16 GB RAM. The final sustained tests ran with the original charger connected.
Live used two threads per decoder on this host.

| Check | Result and scope |
| --- | --- |
| .NET tests on this Windows host | 130 Core + 7 Live tests passed. |
| Windows CI build | Same 137 tests passed; both pinned native runtimes built successfully. |
| Workflow checks on this host | Two Python tests passed, including no automatic release publication and requiring signing for uploaded artifacts. PyYAML was installed only in the ignored QA dependency directory. |
| Signatures and install | Installer and first-party payload signatures are Valid, Fands Software LLC, with timestamps. The installed application DLL matches the signed artifact. |
| Settings and models | Config SHA-256 remained identical after installation and GUI tests. All four downloaded models survived. Saved credentials were reused successfully. |
| Portable native CPU startup | CPU discovery and ordinary model-loading initialization passed on this computer. |
| Local final transcription | Parakeet and Whisper recognized both synthetic English sides and their expected words. GigaAM produced Cyrillic from a local 20-second Russian fixture. Elapsed times including loading were 9.7 s, 81.3 s and 5.3 s respectively. |
| AssemblyAI | The existing saved key recognized two synthetic tracks, preserving `me` / `them` and valid timings, including the delayed second track. |
| Claude and Codex | Both Ready; both generated the expected summary. Installed Settings shows Claude Code 2.1.284 and codex-cli 0.159.0 as answering. |
| Import and viewer hook | Two consecutive imports completed with transcripts, summaries and retained source audio while the viewer stayed open. Hooks ran once; all attempt counters were zero and LastError was null. |
| Real WASAPI capture | 85.2-second capture, four-second pause, Live off/on and Stop passed. Track durations were 85.1897 s and 85.2306 s; Stop 1.038 s, Live off 0.254 s. |
| Captured audio processing | The real WASAPI recording completed through local Parakeet and Media Foundation stereo AAC. Retained M4A was 85.248 s, two channels; raw tracks were removed after successful settlement. No processing attempts were consumed. |
| Batch/live coordination | Signed-package 120-second dual-stream test passed; a real Parakeet task completed with five segments after live stopped. Maximum reported packet lag 1.921 s, Stop 1.095 s. |
| Native worker failure | Killed only the verified active system decoder belonging to an isolated test. Its priority was AboveNormal. Live reported failure at 33.4 s; recording continued to 56.2 s, both WAV tracks remained readable and aligned, Stop 0.358 s. |
| Signed-package sustained live | Full 510-second test passed, no errors. Both sides recognized: 2,886 microphone and 1,302 system characters. Maximum reported packet lag 1.780 s, Stop 0.634 s. |
| Installed GUI | Idle panel and Start placeholder visible immediately; recording showed live text; Pause/Resume worked; Live off folded the panel. The existing two-minute limit stopped the manual recording as `max-duration`. The saved live text reopened from its link. |
| Installed end-to-end recording | That 120-second recording completed AssemblyAI, speaker naming, Claude summary and stereo M4A retention; viewer hook ran, all attempt counters zero, LastError null. |

The final application DLL SHA-256 is
`3EFF5D02E7113BC38E738D9B180378E3F7ADF37959AD9E2B4B4B66C4551E2412`.
Local logs, result JSON and audio fixtures are in the ignored
`windows/artifacts/beta14-qa/` directory; credentials and meeting audio are not
included in this report or committed.

## Observations and remaining manual checks

Earlier normal-priority tests stopped live recognition under CPU contention,
including one after connecting a weak charger. Windows Update and Defender were
also active, so the charger alone is not established as the cause. An equivalent
510-second run with elevated decoder priority and the original charger passed:
maximum reported packet lag 1.921 s, Stop 0.579 s. The signed-package run above
validates the final implementation separately.

Packet lag measures how far the last processed audio is behind the capture
clock; it is not end-to-end word latency. Native lookahead, frame collection and
model loading add delay. One cold load took about 30 seconds; warm loads were
about 3–5 seconds. Loading is shown in the interface. Whisper was considerably
slower than Parakeet on this CPU.

Real capture verified the microphone device format and its continuous track,
and synthetic loopback speech was recognized. Microphone speech recognition
was exercised by recorded PCM fixtures; the tester should still speak into the
actual microphone during a call.

Before production, manually exercise a real Zoom/Teams/browser call with the
normal headset, microphone speech, changing/disconnecting the audio device,
sleep/wake and sign-out. The full ten-minute capture with five minutes of
loopback silence, OS appearance/language combinations and a published-update
round trip were not performed in this consolidation run. OpenAI and ElevenLabs
have no saved keys on this computer; Ollama is not running, so those backends
were not exercised. See [the hardware checklist](windows-hardware-checklist.md).
