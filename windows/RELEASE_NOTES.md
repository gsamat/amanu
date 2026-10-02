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
