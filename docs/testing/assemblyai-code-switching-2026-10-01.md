# AssemblyAI code switching candidate — 2026-10-01

Source: `ee5c30709652f943d201b2cdbf1bf08d9c6c4063`, on the Windows 0.6.0 release candidate branch.

## Change

Both Windows and macOS always send `language_detection_options.code_switching: true` to AssemblyAI. Automatic language detection remains enabled. If a preferred language is configured, its existing expected-language and fallback hints are retained.

The existing single multichannel request for two-sided recordings is preserved. There are no separate per-channel transcription jobs, no model change, and no audio-encoding changes. The experimental per-channel implementation and its mono AAC bitrate adjustment were reverted before this candidate.

The response/job cache key includes `code-switching-v1`, so a subsequent transcription does not reuse a response or outstanding job submitted without the new option. Existing completed recordings are not automatically retranscribed.

## Validation

- On the user's Windows host, the isolated committed source passed 133 Core tests and 20 application/live tests (153 total, zero failures or skips).
- Four request cases cover mono/stereo audio with automatic/hinted language detection. They verify the serialized API option and preservation of multichannel, diarization and language hints.
- macOS request tests cover automatic mono/stereo and hinted requests; cache tests verify separation from pre-option responses.
- [Signed Windows build](https://github.com/gsamat/amanu/actions/runs/36831052488): passed; 153 tests, x64 publishing, native runtime builds, packaging and timestamped signatures verified. Production publishing was disabled.
- [macOS CI](https://github.com/gsamat/amanu/actions/runs/36831038602): passed; 746 tests in 100 suites, universal release build, LocalVQE and landing checks, and 16 release-script tests.

## Recognition limitation

An earlier real AssemblyAI check on a private copy of the user's 69.7-second English/Russian stereo recording verified that the API accepts this option, both with automatic language detection and with Russian/English hints. The short Russian portion was still missed or rendered phonetically. This candidate must not be described as fixing that specific recording.

Per-channel experiments could recognize both sides, but the user declined that architecture. No such change is included. The user's current recording and transcript are left intact; the recording was not repaired or retranscribed by this change.

## Local installation

Installed signed `0.6.0+ee5c30709652f943d201b2cdbf1bf08d9c6c4063` in the normal user installation. Installer SHA-256: `59F0B531D3D134C5390B872C87008E37720FCB26829E520118BAF9C0613BF72F`; installed `Amanu.dll`: `B37C115AF2E1B75550FC7490565216DDAF00FF282782CB54C2CA842140C83278`. Installer, executable and application/core libraries have valid Fands Software LLC signatures; the installer timestamp is present.

Configuration was preserved byte-for-byte, and the four downloaded model files retained their inventory. Russian UI, live transcription, automatic recording and the user's two-minute maximum remain configured. The installer is also saved in `%USERPROFILE%/Downloads/Amanu-0.6.0-code-switching`.

Computer Use verified the actual installed GUI. Restart rearmed automatic recording while Edge still held the microphone; the new recording was manually stopped to restore the prior standing-down state. It captured about 63 seconds with no recognized speech. Its completed AssemblyAI response confirmed `code_switching: true`, `language_detection: true` and `multichannel: true`; the application correctly reported “В записи не слышно речи.” The stopped app is idle, automatic recording remains enabled but paused until the call ends, and live decoders report ready. The empty recording is retained; existing user recordings were not changed.

This verifies API acceptance and application startup, not improved multilingual recognition. The earlier extensive recording, live, import, recovery and local-engine checks on `b7c7ee9` are documented in [the original release QA report](windows-0.6.0-qa-2026-10-01.md). Temporary installation/probe scheduled tasks were removed; the clean source test worktree was archived.

## Publication

[PR #23](https://github.com/gsamat/amanu/pull/23) remains a draft. The build is for local acceptance. Master, production tags, the public release and the update feed are unchanged.


