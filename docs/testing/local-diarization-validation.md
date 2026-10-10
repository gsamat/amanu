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

## Original Community-1 verification record

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

## Model-choice follow-up, 2026-10-10

The user approved the rendered layout before implementation. Settings and
first-run Setup now place a separate Diarization section immediately below
the local transcription models, before language. The same radio-card control
offers Nemotron 3, LS-EEND AMI and Community-1 with short characteristics.
The section requires “On this Mac”; model selection and download additionally
require the optional diarization switch. Selection alone never downloads a model.

Nemotron 3 is the default for new requests. Existing saved requests without
a model retain Community-1, including the historical cache fingerprints.
Each model has an independent verified cache and inference lease. Unsupported
saved model IDs block processing without discarding audio or provisional text;
valid terminal failures still clear obsolete provisional text.

| Check | Result |
| --- | --- |
| Full ordinary `AMANU_REQUIRE_LOCALVQE=1 swift test --no-parallel` | 865 tests/115 suites, 50.816 s; four issues: three affected fixture expectations and the unchanged `MeetingLanguagesTests.swift:25` ordering assertion |
| Corrected interface/schema fixtures | Exact model/license proper-name allowlist and held Setup key updated; focused 51 tests/4 suites passed in 6.629 s; product source unchanged, full suite not repeated |
| Focused legacy replay and unsupported-model recovery | Passed; old completed Community-1 replay needs no audio or fresh inference; unreadable requests retain recovery data and refuse overwrite/skip |
| Failed candidate cleanup | Both terminal-failure cleanup and unreadable-state retention checks passed |
| Native runner with hostile ambient variables | All six runner tests passed with inherited `NEMO_SPEECH_DIAR_ONSET` and `GGML_LOG_LEVEL`; fake child observed both removed |
| Native helper build | Pinned default-source build passed; seven arm64 Mach-O files and 147 objects target macOS 14.2, with embedded Metal and relative library closure |
| Helper-verifier regression | Positive original/copied closure accepted; absolute alias, escaping relative alias and extra absolute RPATH rejected |
| Script suite | All 25 Python tests passed, no skips |
| EN/RU native views | Setup and Settings, light/dark, narrow 640-point layout and cloud-only state passed; copy and bottom spacing visually inspected |
| Actual selected-model engine | Nemotron returned 6/6 voices, DER 3.08% on NOTSOFAR eval MTG32175; LS-EEND AMI returned 4/4, DER 6.07% on AMI 600–780 s |
| Whole-branch integration corrections | Cloud→Whisper timing, terminal candidate cleanup, unreadable-request failure accounting and ordinary retranscription-off cases reproduced RED; five focused checks passed after corrections |
| Changed-source ordinary suite | 870 tests/115 suites, 61.481 s; only the unchanged `MeetingLanguagesTests.swift:25` baseline failure remained |
| Final GigaAM replacement state | New regression reproduced a duplicate inference; returning the updated in-memory speaker state fixes it while preserving the previous generation until commit |
| Final affected lifecycle/resolver suites | All 42 tests/two suites passed in 2.685 s after the GigaAM state correction; no later full-suite rerun is claimed |
| Actual signed bundled helper | Six of six voices and the same 3.08% DER on public eval MTG32175, 24.714 s including cold initialization; no download; seven-file closure hashes recorded for final-package identity check |

The natural public-corpus comparison, pinned assets, licensing, timing limits
and reproducible selected-engine procedure are recorded in
[the evaluation report](local-diarization-evaluation.md#native-model-comparison-2026-10-10).
The two selected-engine checks used private scratch caches and public audio;
they did not read recordings or modify the ordinary user profile. Their
matching qualification scores establish integration on the stated Mac, not
Russian-call accuracy or end-to-end ASR word attribution.

Scoped reviews closed the cache/recovery, native-closure and explicit-model
preference findings. Whole-branch review found the additional entrypoint and
replacement cases above; their regressions and affected suites passed after
bounded corrections. The final separate signed app, ZIP extraction and GUI
startup are delivery checks recorded in its local `build-info.json`, separately
from these source checks. The helper's seven signed files must match the closure
actually exercised above, so unchanged native inference need not be repeated.

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
The original short-clip evaluation did not verify Parakeet/GigaAM, the old/new
GigaAM WER comparison, 5–8 real voices, natural overlap or Russian Zoom/КTalk
accuracy. The follow-up above adds natural English overlap and six/seven-person
evaluation meetings; Russian and end-to-end ASR checks remain unverified. The corpus has
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

The upstream [PR 49](https://github.com/gsamat/amanu/pull/49) is open for review;
its readiness state does not establish that CI or user acceptance has passed.
No release, feed/version change, production deployment, or installation over
the user's app is part of this task.

## Final local user-test bundle — build 448

The universal `0.6.5 (448)` app was built from `01eb5beb4a083a729649375d55544064ec6a6950` with `make SIGN_ID=- BUILD=448 app`. The bounded build passed in 225.289 seconds (`tradeos-check-IIVZfn`); the independent package/extraction check passed in 7.140 seconds (`tradeos-check-jcbtDx`). Later documentation-only commits do not change the compiled source.

The local archive is `amanu-0.6.5-model-choice-01eb5be-macos-universal.zip`, 24,201,702 bytes, SHA-256 `0faba09ed55dfde220c2130223a313d051ec9f7ee4df32692f70f39e9879a114`. The original bundle, copied app and independently extracted archive passed metadata, universal-main, deep/strict ad-hoc signature, macOS 14.2 compatibility, relative native dependency closure and actual main/helper help checks. All 22 license files retain their source bytes; ZIP contents, symlinks and permissions match. All seven signed native helper files match the earlier actually exercised bundled Nemotron helper, so its public 6/6-speaker, 3.08% DER result applies to this unchanged runtime. No notarization was performed.

A byte-identical app was launched through LaunchServices from a temporary read-only image with an empty, private profile. A process sample confirmed it reached the existing `ApplicationRelocation` move-to-Applications modal rather than crashing. Computer Use exact-path selection timed out twice, so actual Settings clicks and packaged GUI interaction remain **unverified**. A proposed writable relaunch was not performed because private CFPreferences isolation could not be established. The diagnostic process was terminated, its temporary image detached, and no recording, download, installed-app replacement or ordinary-profile write was performed. Native EN/RU layout and behavior checks above remain separate evidence, not a substitute for this missing GUI flow.

The ordinary suite retains its documented baseline language-order failure; final affected lifecycle/resolver checks passed 42 tests. Russian meeting accuracy, new recording/capture, actual VoiceOver and execution on physical Intel or macOS 14.2 remain outside executed evidence. Source publication, CI and user acceptance are recorded separately in PR #49.

## Nemotron download correction, 2026-10-10

The user reported a failed download in build 448. The store incorrectly used its local `models/` cache prefix in the remote URL; [the pinned NVIDIA repository](https://huggingface.co/nvidia/Nemotron-3-Diarization/tree/f667ed73aee57d40cc39428eb768b4fd87a0a29e) publishes the GGUF at its root. The old URL returns HTTP 404. Only Nemotron's remote path changed; local paths, model revisions, manifests, cache fingerprints, size/SHA verification and atomic replacement remain intact. The earlier selected-engine qualification used already prepared models and did not establish that this download route worked.

The new URL regression first failed against the old source. An actual `DiarizationModelStore` download using its default URLSession fetch into an empty disposable `/tmp` cache then passed in 31.154 seconds (`tradeos-check-aTNxCD`): 107,012,128 bytes, SHA-256 `08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1`, and verified readiness. The opt-in test accepts `AMANU_DIAR_MODEL_DOWNLOAD_MODEL=nemotron-3` with an explicit `AMANU_DIAR_MODEL_DOWNLOAD_DIR`; its default remains Community-1.

The same screenshot exposed a shared card-layout defect: a long failure status expanded one card and squeezed its neighbours. The noncompact status label now permits horizontal compression and is constrained inside its existing card inset; compact cards retain their prior layout. The native regression reproduced the overflow at 700 and 640 points, then passed. Frame widths allow AppKit's observed one-point rounding. English and Russian light/dark 640-point Settings error fixtures passed and were visually inspected (`tradeos-check-7t8SxP`, `tradeos-check-aT98y8`); the full status remains in accessibility help.

The changed-source ordinary run covered 874 tests in 115 suites, 48.892 seconds (`tradeos-check-rHT6gc`), with only the unchanged `MeetingLanguagesTests.swift:25` Bosanski ordering failure. All affected store, Setup, accessibility and layout suites passed. Native inference was not repeated for this URL/layout correction; the model/runtime bytes are unchanged. Separate local bundle and ZIP verification are recorded below and in the local artifact metadata; actual packaged GUI interaction remains a distinct acceptance limit.

## Corrected local user-test bundle — build 449

The universal `0.6.5 (449)` app was compiled from `e99ba477782e989fef9f50d1cf027debed8fccff` with `make SIGN_ID=- BUILD=449 app`, passing in 158.321 seconds (`tradeos-check-9bSQHG`). The copied app and independent ZIP extraction passed their checks in 6.655 seconds (`tradeos-check-dXYKGK`): exact versions, deep/strict ad-hoc signatures, universal main, macOS 14.2 compatibility, actual main/helper help, seven-file relative native closure, all 22 source-license bytes, and matching files/symlinks/permissions. The signed helper files match the previously exercised runtime byte for byte. Later documentation-only commits do not change compiled product bytes.

The archive is `amanu-0.6.5-nemotron-download-e99ba47-macos-universal.zip`, 24,201,661 bytes, SHA-256 `82ef8d41a63253ae163be252d899c752b483f668c3f5ed47c9fbf147b3d50a1d`. Its local directory also contains `build-info.json`, `SHA256SUMS`, a Russian README and the four native error-fixture PNGs. Model downloads remain explicit; the GGUF is not bundled. Ad-hoc signing is for this local test build, and no notarization was performed.

Packaged GUI interaction was not repeated: the source correction has native frame/appearance evidence and an actual fresh model-store download, while the earlier private LaunchServices/isolation limitations remain recorded above. A real packaged Settings download/retry and user acceptance remain open. There was no installed-app replacement, ordinary-profile mutation, personal audio use, new inference benchmark, merge or public release. Latest source publication and CI are tracked separately in PR #49.

## Shared download progress and cancellation, 2026-10-10

The user requested one reused progress component inside local transcription and diarization model cards, with cancellation. The approved revised mockup places a small xmark button immediately to the right of the native bar and a percentage above it. Model choice, explicit-download behavior and local-mode gating retain their existing contract.

The diarization store now reuses `ModelDownloader` for byte progress and network cancellation. Progress uses the immutable manifest's total bytes across files, is bounded and monotonic, and reserves 100% for verified atomic installation. Missing intermediate/weighted callbacks were reproduced against the completed-file-only implementation (`tradeos-check-NHsMyO`); the focused store and shared-downloader checks then passed 21 tests in three suites (`tradeos-check-tUezVS`).

An actual default Nemotron download into a fresh disposable `/tmp` cache cancelled on the first intermediate callback, left no staged or ready model, and released the lease. The same store then retried successfully with monotonic intermediate progress and final 100% (`tradeos-check-ehlB8j`, 39.050 seconds for the test). The installed file contains exactly 107,012,128 bytes and SHA-256 `08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1`. This is real transport/store evidence; the packaged Settings flow remains a separate acceptance check.

`ModelDownloadProgress` is now the one AppKit accessory reused inside all six local-ASR and diarization cards. It contains a muted percentage and native bar with a small xmark to the right; tooltip and accessibility name identify the model being cancelled. Cancelling retains selection, waits for cleanup, restores Download, and suppresses cancellation errors. Operation IDs reject late callbacks from cancelled attempts. The active diarization Cancel control remains available if its feature is switched off mid-download. Progress callbacks update the owning accessory directly, avoiding repeated hashing of sibling model caches.

The frontend behavior regressions failed before implementation (`tradeos-check-9uMoDW`). The focused integration check passed 110 tests in ten suites, including equal-width 640/700-point card containment (`tradeos-check-oVHei2`, 11.489 seconds). Bounded source review found one HTTP diagnostic regression: the reused downloader's error was being displayed as an opaque Swift error. A card-level HTTP 404 check reproduced it (`tradeos-check-yhHKbb`); using the existing descriptive error then passed all 15 SetupForm behavior tests (`tradeos-check-DSAodX`, 2.592 seconds), and the reviewer closed the finding. English and Russian narrow Settings fixtures generated four images each, covering active local and diarization downloads in both appearances (`tradeos-check-WNbRjz`, `tradeos-check-isC5Y5`); all eight were visually inspected for bar/button containment and bottom spacing. These are native rendered fixtures, not a claim of packaged GUI interaction or actual VoiceOver navigation.

The pinned FluidAudio downloader already propagates task cancellation to its URLSession task and preserves valid Parakeet cache files on cancellation. No new ASR transport or dependency is introduced. Parakeet keeps the existing approximate cache-size progress for its multi-file model; Whisper, GigaAM and diarization use received-byte progress. The changed-source ordinary run covered 883 tests in 115 suites, 55.062 seconds (`tradeos-check-RJFfnv`), with only the unchanged `MeetingLanguagesTests.swift:25` Bosanski ordering failure. All affected suites passed. Separate local build450 packaging follows this verified source checkpoint; no new inference benchmark, installed-app replacement or ordinary-profile mutation is included.
