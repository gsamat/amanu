# Setup window: manual verification

Run this only after the current meeting and recording have ended. Installing
and kickstarting the LaunchAgent replaces the running daemon, so neither step
belongs in the middle of a recording.

## Before installing

- Confirm the menu and status window both say the recording has stopped.
- Confirm the just-finished session has readable audio files before replacing
  the daemon.
- Run the automated checks from the repository:

  ```sh
  AMANU_NO_NOTIFY=1 swift test
  swift build -c release
  ```

## Install and first launch

1. Install the signed build and restart the LaunchAgent:

   ```sh
   make install
   launchctl kickstart -k gui/$(id -u)/me.samat.amanu
   ```

2. Confirm there is one daemon, not two:

   ```sh
   pgrep -fl '(^|/)amanu( |$)'
   ```

3. Confirm Setup opens automatically and the ordinary status window does not
   open in front of it.
4. Confirm **Start at login** is green. It must not say that this copy was
   started outside launchd.

## Access

- Microphone: click **Allow**, accept the macOS prompt, and confirm the row
  turns green. If it was previously denied, confirm the button opens the right
  System Settings pane.
- System audio: click **Allow and test**, accept the prompt, hear the short
  tone, and confirm the row says it heard the tone. Deny once only if it is
  convenient to verify that the same action can be retried afterwards.
- Calendar: verify both Allow and Open Settings paths. Calendar is optional and
  must not block the Done button.
- Close Setup with the red window button once and confirm this behaves like
  **Later**: the window closes and the daemon continues running.

## Layout

- Confirm the section headings — Access, Transcription, Files, Summaries — are
  the small grey labels, each sitting close to its own group and well clear of
  the group above.
- Confirm exactly one Access row is tinted amber: the one the primary button
  is about to act on. A granted row is a single line with its state beside the
  title and no explanation underneath.

## Files

- Confirm the recordings folder row shows the current path in a monospaced
  font, and that **Choose…** writes the new path into `config.json` as
  `recordings_dir` (with `~` when the folder is under the home directory).
- Confirm a folder chosen inside Documents or Desktop still records: make a
  short test recording afterwards and check the files land there.

## Transcription

- Confirm **Whichever works** is selected by default.
- Click the title, description, and empty space inside each transcription card;
  confirm the whole outlined rectangle selects the card. Confirm **Download**,
  key fields, and links still perform their own actions instead.
- Confirm the Parakeet card says either **downloaded** or approximately 600 MB.
  If the model is absent, start Download and verify that the progress bar and
  the megabyte count both advance without freezing the window.
- Confirm the AssemblyAI card always shows **Get a key** and the link opens the
  signup page.
- If an AssemblyAI key is available, paste it and verify **key works**. Do not
  put the key in `config.json`; it should land in
  `~/.config/assemblyai/token` with mode 0600.
- Change the meeting language, close Setup, reopen it, and verify the value was
  persisted.

## Summaries

- Confirm the Summaries switch is on the left, matching the Start recording
  row, and that clicking it disables or enables every backend choice.
- Confirm the Claude Code card is selected for the default `auto` fallback
  chain and shows a visible `answers · <version>` status when Claude runs.
- Click the title, description, and empty space inside each summary card;
  confirm the entire outlined rectangle selects it without swallowing clicks
  on install links, key fields, or the provider selector.
- Confirm Codex is detected from either PATH or the copy bundled in
  ChatGPT.app, and its version status is visible.
- Confirm **Install it** is visible only for a CLI that is missing.
- On **My own key**, switch between Anthropic and OpenAI. Confirm the key
  placeholder and **Get a key** destination both change.
- If keys are available, paste each one and verify **key works** without a paid
  completion. Confirm the files are mode 0600:

  ```sh
  stat -f '%Sp %N' ~/.config/anthropic/token ~/.config/openai/token
  ```

- Confirm Ollama is the slim row under the three cards — still selectable,
  still reporting whether it is installed and running, and naming up to two
  installed models. When Ollama is absent, confirm **Install Ollama** opens
  `https://ollama.com/download/mac`; when present, confirm the link is hidden.
- Turn Summaries off and confirm all backend choices become disabled; turn it
  back on afterwards.

## Audio retention

- Click both the checkbox square and the words **Keep the audio after
  transcribing**; confirm either target toggles the same checkbox.

1. Leave **Keep the audio after transcribing** off. Make a short manual test
   recording with both microphone speech and Mac playback, then stop it.
2. Wait for `transcript.json` to appear. Confirm:
   - `transcript.json`, `transcript.md`, and the summary remain;
   - mic, system, and mixed audio files are gone;
   - `meta.json` contains `"audio_discarded": true`;
   - **Re-transcribe** is disabled for that session.
3. Turn **Keep audio** on and make another short recording. After transcription,
   confirm:
   - one `audio.m4a` remains and the source `.caf` files are gone;
   - the M4A is materially smaller than the source PCM size reported in
     `transcribe.log`;
   - your microphone is audible only in the left channel and Mac playback only
     in the right channel;
   - **Re-transcribe** is enabled and successfully produces a new transcript
     from the archived channels.
4. Optional failure-path check: temporarily select AssemblyAI without a usable
   key, record a few seconds, and confirm a failed transcript keeps the source
   audio. Restore the engine to **Whichever works** immediately afterwards.

## Reopening and restart behavior

- While the daemon is running, execute `amanu setup`. Confirm the existing
  process opens Setup, the command exits, and `pgrep` still shows one daemon.
- Click **Later** or **Done**, restart the LaunchAgent, and confirm Setup does
  not open automatically again.
- Reopen Setup from both the menu-bar menu and the app menu.
- Make one final ordinary meeting test and verify auto-record, transcription,
  speaker naming, summary generation, and the recordings list still work.
