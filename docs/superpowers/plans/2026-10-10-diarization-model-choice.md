# Diarization model choice implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Let a person choose a verified local speaker model in the approved radio-card layout, with Nemotron 3 as the default for new requests.

**Architecture:** Reuse the existing model store, inference lease, session request, cache fingerprints and `ChoiceCard` controls. Add LS-EEND AMI through pinned FluidAudio; run pinned NeMo-Speech.cpp in a bundled subprocess for Nemotron, using the existing cancellation and bounded-output utility. Keep the Community-1 directory and old-session behavior compatible.

**Tech Stack:** Swift 6, AppKit, FluidAudio 0.15.5, CoreML, NeMo-Speech.cpp `8642eaa5cc51efbc17ad0f3e433944ba858a873f`, embedded Metal, CMake.

**Spec:** User-approved mockup of 2026-10-10 and `docs/testing/local-diarization-evaluation.md`; public-corpus evidence and accepted boundaries in PR #49. The user explicitly approved implementation of the displayed mockup.

## Global constraints

- Universal Amanu app, minimum macOS 14.2; local models remain Apple Silicon only. The new native helper may be arm64 and must be guarded by the existing platform capability.
- No Python, PyTorch, external CLI installation, cloud inference, automatic model downloads, Windows changes, merge, public release, or normal-profile diagnostic writes.
- Model IDs: `nemotron-3`, `ls-eend-ami`, `community-1`; ordered as in the approved mockup. Nemotron uses Q8_0 and fixed `v3-offline` chunked Metal inference; LS-EEND uses AMI500ms CPUOnly, four output tracks. No per-recording tuning or speaker-count hint.
- Model source revisions: Nemotron `f667ed73aee57d40cc39428eb768b4fd87a0a29e`; LS-EEND `28ce1b1f8ef186729df63b3886fbaae7bc10c4a1`; Community-1 retains `df2625ac79a7ac6b65ad868fee6d80f320da4232`.
- Diarization is off by default. Missing global model setting selects Nemotron; legacy persisted requests without a model decode to Community-1. Explicit selection is retained. Config errors remain visible.
- The separate “Диаризация” section sits immediately after the local-ASR model block, before the language row. It is visible but unavailable when local transcription is off; cards also disable when diarization is off. Reuse the same local-mode interpretation as the existing cloud/local fallback controls.
- Keep the current busy/release protections, in-use deletion/download locks, independent ASR cache, transcript publication, names, retry/skip and silence handling. A request snapshots its model; no fallback to another diarizer silently.

## Review focus

- Old pending and completed sessions must retain Community-1 provenance and audio-recovery behavior.
- Changing the global setting during processing must affect new requests, not the active request or its cache.
- Deleting an unselected model must not turn off the selected model or delete its sibling directory; in-use models remain protected.
- Cloud-only mode, diarization off, unsupported hardware and bad config must not allow radio selection/download to bypass availability.
- Missing helper, malformed/empty/out-of-bounds native JSON, cancellation and failed download must preserve transcript/audio and give recoverable status without exposing child logs.

### Task 1: Shared catalog, model store and session runtime

**Owner:** backend specialist; not alone in the checkout.

**Files:** `Sources/amanu/Transcription/DiarizationModel.swift` (new), `DiarizationModelStore.swift`, `DiarizationEngine.swift`, `DiarizationTypes.swift`, `DiarizationState.swift`, `LocalDiarizationPipeline.swift`, `TranscriptionCoordinator.swift`, `Sources/amanu/Sessions/PostProcessor.swift`, `Sources/amanu/Config.swift`, `Sources/amanu/Settings/{ConfigKeys,SettingsSchema,ConfigProblem}.swift`, affected config/lifecycle/alignment/model/pipeline tests and existing opt-in evaluation runner.

**Interfaces produced:**

- `DiarizationModel: String, Codable, CaseIterable, Sendable` with cases `.nemotron3`, `.lsEendAMI`, `.community1`; `static default`, `title`, `detailEnglish`, `detailRussian`, `advertisedBytes`, `revision`, `assetDirectoryName`, `primaryAssetPath`.
- `Config.diarizationModel()` and `Config.diarizationModel(in:)`.
- `DiarizationSettings.model`; explicit initializers default to `.default`, legacy decoding defaults to `.community1`.
- `DiarizationState.Request.model` snapshots the choice and defaults legacy JSON to `.community1`; newly queued requests pass the configured choice.
- `DiarizationModelStore.shared(for:)`; model property and nonisolated directory. Legacy `.shared` and static asset APIs retain Community-1 meaning. `init(model: .community1, directory: ...)` supports existing tests. `isReady(at:model:)` has `.community1` as the compatibility default.
- Independent sibling directories under the same cache parent: preserve `diarization` for Community-1; use `diarization-nemotron-3` and `diarization-ls-eend-ami` for the others. Pinned size+SHA checks and notices apply to each catalog.
- `DiarizationEngine` remains the coordinator factory entrypoint. Its prepared manager chooses Community-1, LS-EEND or `NemotronDiarizationRunner`, while the outer actor owns the same model lease and busy/release guard. Fingerprints include model ID, exact assets, runtime/preset and meaningful settings. Threshold applies only to Community-1.

**Consumes:** Task 2's `NemotronDiarizationRunner` interface. Root is the only SwiftPM test/build driver.

- [x] Write focused failing checks for catalog/config default, legacy request decode, request snapshot, independent stores, model cache invalidation preserving ASR, busy/deletion, and unknown model/config.
- [x] Send root the exact focused test filter; root observes the failure before product changes.
- [x] Implement the smallest shared contract and add native LS-EEND initialization from verified local files, full timeline export, padding clipping and no speaker-count hints. Keep overlap.
- [x] Update callers and affected tests; the opt-in Community baseline explicitly selects `.community1`.
- [x] Root runs focused green checks and reviews the complete diff before checkpoint commit.

### Task 2: Bundled native Nemotron runner and reproducible packaging

**Owner:** native backend specialist; independent of Task 1 except interfaces.

**Files:** `Sources/amanu/Transcription/NemotronDiarizationRunner.swift` (new), `Sources/amanu/Subprocess.swift`, `Tests/amanuTests/Transcription/NemotronDiarizationRunnerTests.swift` (new), relevant subprocess tests, `scripts/build-nemotron-diar.sh` (new), a focused packaging verification/self-check if needed, `Makefile`, runtime/model notices under `Resources/Licenses`, `THIRD-PARTY-NOTICES.md`.

**Interfaces produced:** `struct NemotronDiarizationRunner: Sendable`, `init(model: URL, executable: URL? = nil) throws`, `func diarize(_ audio: URL) async throws -> [SpeakerTurn]`. This object does not acquire/release model-store leases. Use `LocalDiarizationRuntimeError.noSpeechDetected` for empty activity; expose a typed missing-helper/unsupported-runtime condition for the coordinator's environment deferral. Core owns any shared error-enum edit.

**Consumes:** Existing mono16k prepared CAF, `SpeakerTurn`, `Subprocess` and the exact verified local GGUF path supplied by Task 1.

- [x] Define failing meaningful tests for invalid/empty/native speaker JSON and prepared-audio conversion/cancellation. Notify root for Swift checks; use a deterministic native packaging self-check for new scripts.
- [x] Stream CAF to a private temporary mono16k WAV, clean it up on all exits, invoke bundled helper using explicit argv and GGUF, fixed Metal/v3-offline preset, no output file. Validate finite positive bounded intervals and speaker IDs1–8; clip only terminal frame padding.
- [x] Add optional child-only environment support to `Subprocess` preserving existing callers. Scrub ambient `NEMO_SPEECH_*`; set nonexistent private `NEMO_SPEECH_MODEL_INDEX` and private model cache to fail closed. Keep output bounded and child errors generic.
- [x] Build pinned NeMo, llama.cpp `bd4f514db14d87fded667787a7a963bfbaa98e89` and SentencePiece `31646a467d2051eb904e0b45de3a73e91fe1c1e3`; all code uses14.2, `GGML_NATIVE=OFF`, embedded Metal. Ship only required relative `bin/lib` dependency closure with licenses and pinned build verification.
- [x] Make the existing build/app recipes produce, copy and sign inner libs/helper before the app; preserve ad-hoc launch fix. Check arm64, minOS14.2, dependencies and actual bundled help. No global installs.
- [x] Root validates the integrated runner on public annotated audio and the final build448 ZIP roundtrip before delivery.

### Task 3: Approved Settings/Setup radio-card controls, storage and diagnostics

**Owner:** frontend specialist; relies on Task 1's declared catalog/store APIs, may prepare tests in parallel.

**Files:** `Sources/amanu/UI/SetupForm.swift`, `SettingsWindow.swift`, `Sources/amanu/Transcription/ModelStorage.swift`, `Sources/amanu/Doctor.swift`; `Tests/amanuTests/{SetupFormBehaviourTests,StatusWindowLayoutTests,DoctorSummaryTests}.swift`, `Tests/amanuTests/Transcription/ModelStorageTests.swift` and necessary native layout fixtures.

**Consumes:** The exact Task 1 APIs above. Add an optional `diarizationModel` identity to `ModelStorage.Model`, preserving non-diarization initializers; list all three models, verify readiness by identity and delete through the matching leased store. Keep existing helper API behavior compatible where used by tests.

- [x] Add failing behavior checks for radio cards/order, local-mode gating, diarization-off gating, explicit download only, changing selected model, independent storage deletion and English/Russian characteristics. Root runs the red checks.
- [x] Move the shared section directly below local model selection; use existing `ChoiceGroup`, `ChoiceCard` and row-height helpers. Characteristics match the approved mockup: Nemotron3 `(Meetings up to8 speakers)`/`(Встречи до8 говорящих)`, recommended107MB; LS-EEND AMI up to4 speakers,45MB; Community-1 compact alternative21MB.
- [x] Snapshot download choice; per-card progress/readiness/retry; disable cards/download when local mode or feature is off, unsupported, config invalid or that operation is busy. Never silently download after selection or switching.
- [x] Update storage names/counts and Doctor to identify the selected model/revision/license/helper readiness; maintain selected-model deletion semantics.
- [x] Root checks both Setup/Settings and both themes/languages, narrow layout, keyboard and radio accessibility properties (actual VoiceOver navigation remains unverified); fix any clipping/bottom-border regression before green checkpoint.

### Root integration and delivery

- [x] Record sanitized primary comparison numbers, distinguish NOTSOFAR eval from train probes, and retain public assets outside Git. No Russian/live-call accuracy claim.
- [x] Inspect every specialist result and scoped diff; run relevant feature/config/recovery/native/layout/packaging tests and one full ordinary suite, documenting known baseline failure separately.
- [x] Read-only whole-branch final review; fix actionable integration regressions and rerun only affected checks.
- [ ] Conventional commit(s) with `Co-Authored-By: Codex <noreply@openai.com>`, verify exact SSH branch/upstream, push and update existing ready PR49 without auto-merge.
- [x] Build a separate universal local user-test app at the verified revision with a new build number; verify signing, macOS floor, actual helper/app startup and independent ZIP extraction. Keep installed app and normal profile untouched.
- [ ] Report chosen default, available models, local ZIP and current CI/acceptance limitations with exact revision evidence. No merge or public release.

This checked-in plan records the pre-publication build448 checkpoint. The app was compiled from `01eb5beb4a083a729649375d55544064ec6a6950`; final packaging passed and source review has no remaining actionable finding. Native layout/behavior checks passed, but actual packaged Settings clicks remain unverified because Computer Use could not read the initial relocation modal. The diagnostic process and temporary image were closed. Current source publication, CI and user acceptance are recorded separately in PR #49.

### Follow-up: shared model download progress and cancellation

Accepted user request, 2026-10-10: local transcription and diarization model cards must reuse one download-progress component. Each active card contains its own progress bar, percentage and Cancel button. Cancelling stops that download, preserves verified installed models and permits an explicit retry. Diarization reports bytes during each file transfer, rather than only completed files. Existing model selection, local-mode gating, immutable manifests and download-only-on-click behavior remain applicable.

The user approved the revised rendered layout on 2026-10-10: a muted percentage above a full-width small native progress bar, with a small xmark Cancel button immediately to its right. Tooltip and accessibility name explain cancellation. The earlier mockup with a text button below the bar is superseded. Backend owns the diarization store and transport tests; frontend owns the shared AppKit component, SetupForm integration and native behavior/layout checks. Root serializes builds/tests and prepares a separate local build450 after integration. Existing native inference qualification remains valid because model weights, inference settings and native helper bytes are unchanged; download, cancellation and card-layout evidence must be renewed.

The shared progress/cancellation implementation and bounded HTTP-diagnostic correction are complete. Interaction and narrow native EN/RU appearance evidence are recorded in [the validation report](../../testing/local-diarization-validation.md); the ordinary suite retains only its documented language-order baseline failure. Build450 packaging and current source publication remain separate delivery checkpoints.
