# Amanu for Windows 0.6.6

- Local transcription now works when Windows usernames, model folders or audio paths contain Cyrillic, CJK, accented characters, spaces or emoji.
- Fixes the native model-loading error "No mapping for the Unicode character exists in the target multi-byte code page", and related failures opening audio and batch lists.
- The runtime build now checks Unicode paths before packaging. No model or transcription-language setting changes are required.

## Validation

- On the connected Windows computer: Release and Debug builds succeeded without warnings, 141 core tests and 38 live tests passed.
- The reported failure was reproduced before the fix. All six Unicode runtime, argument, model, WAV and batch-list checks passed after the fix, including a full local native build.
- Whisper large-v3-turbo Q8 transcribed the public JFK sample successfully on Unicode paths in single-file and batch modes. The Amanu interface reproduced the error with the old runtime, then completed the same recording and displayed its transcript with the corrected runtime.
- Local native validation used LLVM/MinGW. The release workflow additionally builds the pinned runtime with MSVC and verifies signed packages before publication.

# Amanu for Windows 0.6.5

- The recordings table shows the active transcription and summary stage consistently with the selected recording's details.
- A skipped failed recording no longer stays marked as busy. Old queue statuses do not hide failed transcripts; final failed and deferred states remain visible.
- Action buttons update immediately when selecting another recording. Completed recordings with retained audio can be played or queued for retranscription while another recording is processing.
- Finish retries unfinished work on an idle recording. Active, queued, and preparing recordings are protected from file changes and deletion. Processing remains serial.
- Disabled actions explain when audio was not retained or there is no unfinished processing.
- Includes the OpenAI, Anthropic, and OpenAI-compatible provider choices released in Windows 0.6.4.
- The signed installer is named **Amanu-0.6.5-Setup.exe**, with matching inventory and checksums. Updates remain on the stable channel.

## Validation

- On the connected Windows computer: Release build succeeded without warnings; 141 core tests, 38 live tests, and five installer filename/inventory/checksum tests passed on the combined release source.
- The signed release workflow completed successfully. Downloaded public installer, portable ZIP, and full update package match SHA256SUMS. Setup and first-party payloads, launcher, and updater have valid Fands Software LLC signatures with timestamps; packaged application version is 0.6.5.
- The production Velopack GithubSource on the stable channel detected 0.6.4 to 0.6.5, downloaded and verified the full package, and extracted the signed updater into an isolated test directory. The update was not applied to the working installation.
- The 0.6.5 WinGet manifest set passed local validation and all Microsoft validation checks, including installation and installer metadata. PR #445793 is ready for review; catalog availability remains pending merge. Scoop pins the public portable ZIP and its verified SHA-256.
- Queue and action regressions were checked red-to-green on the connected Windows computer. The recordings UI was checked through Computer Use with isolated synthetic sessions and controlled local transcription and summary dependencies.
- In a temporary standard Windows account with a separate profile and HKCU, the signed Setup completed a clean 0.6.5 installation and uninstall, followed by a 0.6.4 installation, native Update.exe upgrade to 0.6.5, and uninstall. All five commands returned zero. Installed versions, timestamped signatures, uninstall registration, application-file removal, and retention of synthetic settings and recordings were verified.
- The temporary account, profile, and staging files were removed. The working user's Amanu 0.6.3 installation, registration, and settings were unchanged. These lifecycle checks used silent installation and native update application; launching and restarting the signed app through its graphical interface were not part of this test.

# Amanu for Windows 0.6.4

- The **My own key** card now offers **OpenAI**, **Anthropic**, and **OpenAI-compatible** separately.
- Choose the compatible option to enter the service’s API URL, model, and token. Switching to OpenAI retains the saved custom URL and selects OpenAI’s own API and key.
- API token hints now say **API key** rather than requiring a `sk-` prefix.
- Existing custom endpoint configurations continue to select the compatible service automatically.
- The installer is named **Amanu-0.6.4-Setup.exe**. The stable update channel is unchanged.

## Validation

- On the connected Windows computer: build without warnings, 141 core tests and 28 live tests passed, and installer version, Authenticode signature and SHA-256 verified.
- The actual setup form was checked through Computer Use using isolated settings: all three providers, URL/model visibility, neutral key hint, custom URL retention, and legacy configuration in light and dark themes.
- The 0.6.4 WinGet manifests passed local validation. Installation, upgrade and uninstall in an isolated Windows profile were not tested because no isolated environment was available.

# Amanu for Windows 0.6.3

- The recording status says **ready** in English and **готов** in Russian
  when no recording is running, in the status window and tray menu.
- Windows and macOS share version **0.6.3**, read from the same `VERSION` file.
  The Windows installer and stable update feed remain separate from macOS.
- Includes the checkbox label fixes shipped in Windows 0.6.2 for the
  Windows light and dark themes.

# Amanu for Windows 0.6.1

- Transcript and summary previews render Markdown headings, emphasis, lists,
  quotes, code, links, task lists and tables. Text can be selected and copied,
  including previews of earlier transcript versions.
- Existing Markdown files display with formatting immediately; meetings do not
  need to be transcribed or summarized again.

# Amanu for Windows 0.6.0

Amanu records meeting audio on Windows 11 x64, transcribes conversations,
and prepares summaries with the configured local or cloud service.

- Manual recording and automatic recording when meeting apps use the microphone.
  Automatic recording starts after three seconds by default on Windows and macOS.
  Short automatic recordings are discarded after stopping; the first 45 seconds
  of a retained meeting are kept.
- Local live transcription of microphone and call audio with the Nemotron streaming model.
  When Live transcript is enabled, its decoders load at startup and remain ready
  between recordings. Turning it off releases them. Idle live decoders allow
  completed recordings to be processed.
- Local and cloud engines for final transcripts, with speaker names and summaries.
  Long Windows Parakeet tracks are processed in bounded portions with overlapping
  context and meeting-relative word timestamps to limit memory use.
- Recordings management, import, playback, and re-transcription.
  Re-transcription shows queued, active, waiting, and failed states for its engine.
  Earlier transcripts remain available during processing and after completion,
  with engine tabs for multiple results and transcript, speakers, and summary tabs
  for the selected result. A single transcript uses only the inner tabs.
- English and Russian interface, Windows light and dark themes.
- The application and installer are named Amanu. Updates use the stable channel.

Local models are downloaded in Settings. Live transcription uses a separate
model of about 750 MB and processes audio on this computer.
