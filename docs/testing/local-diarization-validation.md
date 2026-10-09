# Local diarization validation

Implementation scope: [ekho/amanu issue 1](https://github.com/ekho/amanu/issues/1).
This report distinguishes deterministic checks from native-model and application
checks. A passing unit suite does not establish diarization quality on meetings.

## Source and environment

- Fork and upstream base: `c5950c5aeaaa2ebac6e744a9021fc1b100a39f1b`.
- Feature branch: `ekho:codex/local-speaker-diarization`.
- Related [upstream PR 37](https://github.com/gsamat/amanu/pull/37) was open at
  `aca492d6de923414692837915f68536837eb6224` when implementation started.
  Its author is ksmarty. Its offline VBx integration informed this change;
  coarse whole-segment speaker assignment is not the acceptance target.
- FluidAudio: locked 0.15.5,
  `19600a485baa4998812e4654b70d2bab8f2c9949`.
- Hardware: Apple M3 Pro, 18 GiB RAM, arm64.
- OS: macOS 26.7.1, build 25G241.
- Compiler: Apple Swift 6.4, swiftlang-6.4.0.34.1.
- Xcode: 27.0, build 27A266a; first-launch readiness passed after installation.

## Verification record

| Check | Result |
| --- | --- |
| Clean fork/upstream refs and separate feature branch | Verified |
| Initial `make verify-localvqe` | Blocked by missing CMake |
| Build prerequisite | CMake 4.4.4 installed; original source preserved for baseline |
| Baseline LocalVQE verification | Passed for arm64 and x86_64; model digest and native smoke passed |
| Baseline Swift tests | 767 tests; after correcting the archived LocalVQE lookup, one existing `MeetingLanguagesTests` ordering assertion remains; targeted rerun: 50 tests, one issue |
| New deterministic alignment/pipeline/lifecycle/config/CLI checks | Passed in the final full-suite run, including word timing, real PCM/AAC I/O, semantic generation/replay, cache, retention, recovery, settings and translation regressions |
| Full `AMANU_REQUIRE_LOCALVQE=1 swift test --no-parallel` | 833 tests/113 suites; exit 1, one unchanged baseline failure at `MeetingLanguagesTests.swift:25` (`tail.first == "Bosanski"`); no new failures |
| `make build` (arm64 and x86_64) | Passed on Xcode 27.0; 125.603 s including LocalVQE preparation |
| `make app` (local bundle, no installation) | Passed; 11.638 s, strict code-signature verification, all required universal slices and macOS 14.2 compatibility verified |
| Final shortened model title | 23 model-storage/translation tests passed; rebuilt `make app` passed (123.769 s) with signature/universal/macOS 14.2 checks |
| Landing and release-script checks | Landing passed; 23 Python tests passed with Xcode installed, no skips |
| EN/RU native windows, light/dark appearances | Eight screenshot tests per language passed, 34 PNGs per language; settings rerender passed after shortening the model title; eight appearance-switch pairs matched decoded pixels |
| Explicit diarization model download/verification | Passed: all 32 pinned assets verified; one opt-in test, 27.105 s |
| Real diarization-model smoke and CAF/AAC comparison | Passed mechanically: 12 observations over four real AMI voices; quality is weak, see results below |
| Native Whisper timed-word smoke | Passed: 21 timed words, all valid, three punctuated words; one of three segments had no word payload and requires turn fallback |
| Annotated Russian meeting evaluation | Unverified; no permitted annotated Russian corpus supplied |

## Local ad-hoc launch regression

The first local test bundle, 0.6.5 build 444 from
`436a8d1c8cb251de116251da195a0d0f39446661`, passed static signature checks but
aborted before `main` when dyld rejected Whisper's signature. The ad-hoc app
had Hardened Runtime enabled and no Team ID for library validation. Re-signing
only the executable in an isolated copy without runtime flags made its
`--help` launch succeed, confirming the packaging cause.

The corrected recipe clears runtime flags only for ad-hoc development builds;
certificate signing keeps Hardened Runtime. A native executable/dylib regression
failed with the old recipe and passed with the fix. All 25 Python script tests
passed without skips. The build 445 candidate passed `make app`, including the
new bundled `--help` startup check, and opened the Russian first-run window via
LaunchServices with recording and processing disabled in a diagnostic profile.
This establishes startup on the stated Mac, not capture or diarization quality.
`--help` checks linked-at-startup frameworks; LocalVQE is loaded later by echo
processing and is not exercised by that command.

## Native model results

Models and permitted corpus audio stayed outside the checkout. The public
AMI source, pinned revision, license and deterministic crop command are in
[the evaluation procedure](local-diarization-evaluation.md). Its fixed
14.485-second crop contains four distinct people, four non-overlapping turns,
27 reference words and half-second separators. Annotation boundaries were
checked programmatically against the source annotations; this is a constructed
English smoke, not a natural meeting or a listening audit.

The crop was converted to mono 16 kHz Float32 CAF and 32 kbit/s AAC with
macOS `afconvert`. Each contains 231,760 valid decoded frames. The lossy AAC
has a different PCM fingerprint; reruns of each prepared input reuse its
exact PCM. The opt-in evaluator ran thresholds 0.6/0.7/0.8 twice per format.

| Threshold | CAF detected voices | AAC detected voices | CAF DER | AAC DER |
| --- | ---: | ---: | ---: | ---: |
| 0.6 | 2 | 2 | 54.33% | 54.33% |
| 0.7 | 2 | 2 | 54.33% | 54.33% |
| 0.8 | 2 | 1 | 54.33% | 70.02% |

Both runs gave the same scores. DER uses a 0.25-second collar and global
one-to-one speaker mapping; overlap-included/excluded scores agree because
the reference crop has no overlaps. Scored reference speech is 10.985
speaker-seconds: missed speech is 4.474 s, false alarm 0 s, and confusion
1.494 s (3.218 s for threshold 0.8 AAC). Two detected voices demonstrate
native inference, but do not demonstrate correct identification of all four.
There is no basis here to increase the default threshold from 0.6 to 0.8.

The first run measured 0.166–0.330 s per inference, 0.0115–0.0228 wall
seconds per audio second, and process peak RSS up to 236,666,880 bytes.
Model preparation took 1.868 s for the first load in that process and
0.075–0.081 s for subsequent threshold loads. These are short-clip figures
on the stated Mac, with potentially warm OS caches, not meeting-length or
model-only memory promises.

The model revision is `df2625ac79a7ac6b65ad868fee6d80f320da4232`;
its verified manifest fingerprint is
`a5f266162b3237b566e22e79c868d2c1895c87f798f70a4b543c07ce883d7a47`.
The numeric report remains under `.build/evaluation/ami-caf-aac.json`.
The final report-field verification passed seven tests/two suites in 2.452 s
and preserved all twelve scores. It measured 0.149–0.205 s per inference,
0.0103–0.0142 wall seconds per audio second, process peak RSS 287,883,264
bytes, and 0.190/0.069/0.068 s preparation at the three thresholds in an
already warm environment. Every CAF row used source fingerprint
`4302ee18157013eb479e0240ac8ef52dfa4b41d168fb39a048098dd316549225`;
every AAC row used
`6186ac004ef0eedefe85d7c4e865bdb7d29bf23fdb776914526e78f4889740ca`.
Run it with the documented evaluation environment variables and:

```sh
swift test --no-parallel --filter DiarizationEvaluationTests
```

Native Whisper was checked separately with the pinned
`ggml-large-v3-turbo-q5_0.bin` and this CAF. The explicit
`AMANU_WHISPER_MODEL` and `AMANU_WHISPER_AMI_AUDIO` paths enable:

```sh
swift test --no-parallel --filter WhisperRealWordTimingTests
```

That one-test run took 19.764 s. All 21 returned words had finite, positive,
in-range times and preserved their segments' lexical content. One segment
had no validated words; the production pipeline reports turn resolution for
that fallback rather than invented word precision.

ASR WER, speaker-attributed word errors, native PR #37 controls, native
Parakeet/GigaAM, the old/new GigaAM WER comparison, 5–8 real voices, natural
overlap, and Russian Zoom/КTalk accuracy remain unverified. The corpus has
reference text, but actual timed ASR output was not supplied to the metric
runner; absent word/control fields are not zero scores. Pure regressions
cover the older whole-segment alignment counterexamples and more than
four/twenty-six labels; they do not replace those native quality checks.

## Acceptance boundaries

Native AppKit shots were generated with the existing `WindowShots` and
`WindowGallery` suites. Visual inspection covered the local speaker switch,
model storage row, pending/failed/completed recording states, retained-audio
notice, retry/skip actions and unknown-speaker warning in EN/RU/light/dark.
The new model title initially truncated and was shortened; both language
settings shots were refreshed. Images use synthetic gallery sessions and
remain outside Git. To reproduce:

```sh
mkdir -p /tmp/amanu-shots-en /tmp/amanu-shots-ru
AMANU_SHOTS=/tmp/amanu-shots-en swift test --no-parallel --filter 'Window(Shots|Gallery)'
AMANU_SHOTS_LANGUAGE=ru AMANU_SHOTS=/tmp/amanu-shots-ru swift test --no-parallel --filter 'Window(Shots|Gallery)'
```

These offscreen pictures do not establish real clicks or capture permissions.
Native switches and hosted pickers have the rendering limits documented in
`window-shots.md`; state assertions and callback tests were run separately.
A fresh automatic-recording call, physical Intel and older-macOS runtime
remain unverified. No recording/capture code was rewritten to create a smoke.

The feature is opt-in and applies to the local batch route on Apple Silicon.
The live transcript and cloud transcription routes retain their existing
behavior. Overlapping speech can be marked ambiguous; this does not recover
unrecognized words or separate overlapping audio sources.

The required evaluation command, input contract, metric definitions, and
privacy limits are documented in `local-diarization-evaluation.md`. Evaluation
audio and annotations stay outside Git. No real meeting, transcript, calendar,
credential, or user configuration is part of this change or public evidence.

Independent source review found no remaining actionable P1/P2 issue in the
corrected generation identity, candidate cleanup, nullable sidecar publication
and recovery paths. That review is separate from the executed tests and does
not establish model quality. The existing language-order failure is preserved
and reported; neither that assertion nor the CI checks were weakened.

The upstream PR remains draft until its required unverified checks are resolved.
No release, feed/version change, production deployment, or installation over
the user's app is part of this task.
