# Windows Amanu 0.6.0 release candidate — 2026-10-01

## Candidate and installation

- Signed Windows payload: `b7c7ee9c9141e230b3a3351ae3bcd562b808e4c7`.
- [Windows build and signing](https://github.com/gsamat/amanu/actions/runs/36800113341): successful; publishing disabled.
- Product version installed on the user's Windows host: `0.6.0+b7c7ee9c9141e230b3a3351ae3bcd562b808e4c7`.
- Installed `Amanu.dll` SHA-256: `0F9B0EC8ADC55D57B652374A062CBD923DFC266A0D5B74BB97AC96A65CDA0641`.
- Installer, application, core library and local CLI: valid Fands Software LLC Authenticode signatures with timestamps. Package signature verification also passed in CI.
- Start menu contains `Amanu.lnk`, with no remaining Amanu Beta shortcut. The package uses the stable update channel.
- Installer and accompanying release assets are in `%USERPROFILE%/Downloads/Amanu-0.6.0`. Older local installers were backed up separately.
- Configuration was byte-for-byte preserved through both candidate installations. Russian language, the saved AssemblyAI credential, Codex summaries and the four downloaded models remain available.
- The configuration does not override the start delay, so the installed default is three seconds. Automatic recording remains off and the user's existing two-minute maximum remains configured.
- Later commits change CI and documentation only; the Windows application and test source match the signed payload.

## Included changes

The candidate includes the consolidated Windows implementation, the neighbouring session's live decoder preloading and Amanu branding changes, consistent Russian automatic-recording labels, and a three-second default start delay on Windows and macOS.

Live decoders load while Amanu is idle, remain ready between recordings and are released when live transcription is disabled. Completed recordings can process while the preloaded decoders are idle.

Long Windows Parakeet inputs now use sixty-second portions with one second of context on either side. Word timestamps are restored to the meeting timeline, and overlapping context is assigned to its owning portion. This bounds native attention memory. GigaAM and Whisper retain their existing processing modes.

The 45-second threshold discards an entire short automatic recording after stopping. It does not remove the first 45 seconds. The stop delay remains 15 seconds and is excluded from the short-meeting decision; manual recordings are retained independently of this threshold.

## Automated checks

| Check | Result |
| --- | --- |
| Windows Core tests | 133 passed |
| Windows application/live tests | 16 passed |
| Windows self-contained x64 publish, native runtimes, packaging and signing | Passed |
| Local native CPU enumeration and ordinary CLI startup | Passed on this Windows host |
| macOS Swift suite | 745 tests in 100 suites passed |
| macOS universal release build, LocalVQE verification, landing checks | Passed |
| Release-script tests | 16 passed |

[macOS CI](https://github.com/gsamat/amanu/actions/runs/36801235619) passed after changing the Swift test command to `swift test --no-parallel`. Earlier parallel runs failed the import-picker assertions, timed out a subprocess test and hung in UI tests until the job deadline. Several suites manipulate shared NSApplication windows and configuration; per-suite serialization did not serialize them against other suites. No tests were excluded or their assertions relaxed. The new three-second default test passed in both the earlier parallel run and the successful serial run.

## Windows application and audio checks

Tests ran on the connected Windows computer, including actual GUI interaction through Computer Use. macOS CI is not a substitute for these Windows checks.

| Scenario | Observed result |
| --- | --- |
| Final installed application's startup | Russian UI; live status ready before recording |
| Final installed application's 120-second recording | Live text, pause, automatic maximum-duration stop, AssemblyAI transcript, participant names, Codex summary and viewer hook completed |
| Retained audio for that recording | Stereo M4A, 119.936 seconds; transcript contains the synthetic Friday report request on the call side |
| Final installed application's manual pause/resume | Live text continued after resume; manual stop; 24 seconds paused; complete stereo M4A of 80.725 seconds, transcript, names and summary |
| Claude and Codex detection and summary | Both CLI probes reported Ready; both answered a synthetic meeting-summary request |
| AssemblyAI saved credential | Two synthetic tracks recognised with correct sides and positive timestamps; no credential printed or changed |
| Final signed Parakeet | Synthetic two-side recognition passed in 5.8 seconds |
| Final signed Whisper | Synthetic two-side recognition passed in 47.9 seconds |
| Final signed GigaAM | Local Russian fixture recognised with Cyrillic text in 3.9 seconds |
| Final signed four-item local queue | All four imports completed; re-transcription completed; no HTTP requests; audio retained |
| Final signed cloud error handling | Mock HTTP 503 and network failures fell back to local Parakeet in auto mode; explicit cloud HTTP 401/503 deferred, retained source audio, and spent zero recording-failure attempts |
| Russian and English GUI | Main controls and settings inspected in an isolated Debug profile; long Russian automatic-recording label fits the 360-pixel main window |
| Keyboard operation | Tab navigation and Space toggled automatic recording on/off in the isolated profile |
| Unreadable configuration | GUI warned; attempted change was refused; corrupt file was not overwritten; restoring the file removed the warning |

Only synthetic speech was intentionally uploaded for cloud validation. The existing bilingual recognition fixture and the long raw capture were processed locally. Keys were read from Windows Credential Manager and did not enter the repository or report.

## Extended capture, recovery and resource checks

- **Ten-minute real WASAPI capture:** 601.591 seconds, with five minutes between two periods of synthetic speech. Microphone WAV was 601.593 seconds and system WAV 601.558 seconds. Live speech resumed after the quiet interval with no live error. Stop took approximately 1.3 seconds.
- This host's process-loopback recorder supplied 30,000 silent packets during those five minutes. The first QA assertion expected zero packets and therefore failed; the recording and live continuation were valid. This result must not be described as a real packet-free interval.
- **Separate five-minute packet-free live test:** synthetic PCM was withheld from both channels while the capture clock advanced. After the gap, both sides resumed recognition, with no live error; stop took 661 ms. The initial run overlapped independent native batch loads and stopped with overload protection. The repeat after those loads finished passed. Independent QA processes do not share the application's in-process CPU gate.
- **Long local processing:** the original unbounded Parakeet call used approximately 9 GB and exceeded the QA's 15-minute deadline. After the fix, native private memory observed during the same long recording was approximately 1.7 GB; processing completed, generated 106 segments on the original timeline, archived the full stereo M4A at 601.600 seconds and left zero attempts/errors. This check used the release-built application source later signed as `b7c7ee9`.
- **Abrupt component-host exit:** actual Windows capture/live components exited without disposal after approximately 56 seconds. Both WAVs remained readable; SessionStore recovered the marker; child live decoders exited.
- **Whole GUI application interruption:** an isolated Debug build of the release source was terminated during real recording after live text was visible. Only that verified QA executable/PID was targeted. Both live children exited. Restarting the same profile recovered the session automatically, transcribed it locally, and produced stereo M4A of 133.888 seconds against a 134-second recovered meeting duration. The ledger had zero attempts/errors, the marker was gone and the viewer-hook state was settled.
- **Eight live on/off cycles:** off completed in 549–620 ms, parent private memory did not grow beyond its second-cycle baseline, and the child workers were released. The live implementation used here is unchanged in the final signed candidate.
- Isolated GUI processes and temporary scheduled tasks were cleaned up. The installed user's Amanu remains available with live enabled and automatic recording off.

Machine: Intel i5-10310U, four physical/eight logical cores, 16 GB RAM. AC power was confirmed; battery was at 99%. Local evidence and harnesses are under ignored `windows/artifacts/release060-qa`; no audio or credentials are committed.

## Manual acceptance and publication

The [integration PR](https://github.com/gsamat/amanu/pull/23) remains a draft. Master was not merged, no production tag was created, and no release/update feed was published.

Before publishing, the user should record one real meeting and verify microphone/call audio, the first words after the three-second start wait, live text, final transcript, summary and playback. The installed profile currently has automatic recording disabled and a two-minute maximum; these explicit preferences were preserved pending the user's answer about restoring the normal 300-minute maximum.

Actual Zoom device switching, physical headset unplug/replug or Bluetooth changes, sleep/wake and sustained real-call use require manual hardware checks. Windows default-microphone routing is implemented and inspected, but those physical flows were not exercised here. OpenAI/ElevenLabs cloud keys and a running Ollama server were unavailable, so live requests to those backends were not performed. No physical macOS recording or device-switch test ran on this Windows host.
