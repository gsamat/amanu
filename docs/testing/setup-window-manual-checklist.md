# Setup window: manual verification

Last run 19 August 2026, against `Amanu.app` 0.2.0. Most of it can be driven
without hands — a real click at a screen point plus `~/.config/amanu/config.json`
answers nearly every question here — and that is how it was run. The items that
genuinely need a person are marked **by hand**; they are the ones involving
speech, sound coming out of the Mac, a permission that has to be denied, or a
CLI that has to be missing.

That run found one real defect: the **Summaries** switch had no target and no
action. It slid under the finger, wrote nothing, disabled nothing, and every
meeting was summarised by a model the person had just switched off. Fixed. It
is the reason to actually run this list rather than file it.

Run it only after the current meeting and recording have ended. Replacing the
installed application closes the copy that is running, so it doesn't belong in
the middle of a recording.

## Before installing

- Confirm the menu and status window both say the recording has stopped.
- Confirm the just-finished session has readable audio files before replacing
  the application.
- Run the automated checks from the repository:

  ```sh
  swift test
  swift build -c release
  ```

## Install and first launch

1. Install the signed build and start it:

   ```sh
   make app
   rm -rf /Applications/Amanu.app && cp -R .build/Amanu.app /Applications/
   open /Applications/Amanu.app
   ```

   Quit the running copy first (`osascript -e 'tell application "Amanu" to quit'`).
   Deleting the bundle out from under a running process does not stop it, and
   the survivor answers the doorbell that the new copy is trying to ring.

2. Confirm there is one copy, not two:

   ```sh
   pgrep -fl Amanu.app
   ```

3. Confirm Setup opens automatically and the ordinary status window does not
   open in front of it. Setup only opens when it is pending, so to see this
   again, quit, remove `completed_at` from `~/.config/amanu/setup.json`, and
   relaunch. On a pending launch `amanu setup` should be the only window there.
4. Confirm **Start at login** is the first Access row and is green, and that
   System Settings → General → Login Items lists Amanu.

## The window scrolls

Say this before anything below, because it costs an hour otherwise: the form is
taller than the window. **Summaries** and the automatic-recording switch are
below the fold, and someone who does not scroll will conclude they were
deleted. Scrolling from a script:

```sh
osascript -e 'tell application "System Events" to tell process "Amanu" \
  to set value of scroll bar 1 of scroll area 1 of window "amanu setup" to 1.0'
```

## Access

The section is four rows: Start at login, Microphone, System audio, Calendar.

- Microphone: click **Allow**, accept the macOS prompt, and confirm the row
  turns green. **By hand** if it was previously denied: confirm the button
  opens the right System Settings pane.
- System audio: click **Allow and test**, accept the prompt, hear the short
  tone, and confirm the row says it heard it — it reads `heard the tone · <date>`
  afterwards, and offers **Test again**. **By hand**: the tone is the point.
- Calendar: verify both Allow and Open Settings paths. Calendar is optional,
  must not block **Done**, and while it is the only thing ungranted the footer
  still reads *Everything amanu needs is granted*.
- Close Setup with the red window button once and confirm this behaves like
  **Later**: the window closes, the app keeps running, `pgrep` still shows one.

## Layout

- Confirm the section headings — Access, Transcription, Files, Summaries — are
  the small grey labels, each sitting close to its own group and well clear of
  the group above. Summaries is the exception: its heading carries the section
  switch to the left of the word, matching the automatic-recording row.
- Confirm at most one Access row is tinted amber: the one the primary button is
  about to act on. With everything granted, **no** row is amber — the tint
  follows the pending grant, and Calendar being optional is not one. A granted
  row is a single line with its state beside the title and no explanation
  underneath.

## Files

- Confirm the recordings folder row shows the current path in a monospaced
  font, and that **Choose…** writes the new path into `config.json` as
  `recordings_dir` (with `~` when the folder is under the home directory).
- **By hand:** confirm a folder chosen inside Documents or Desktop still
  records — make a short test recording afterwards and check the files land
  there.

## Transcription

- Confirm **Whichever works** is selected by default, and that selecting it
  removes `transcription.engine` from `config.json` rather than writing a name.
- Click the title, the description, and empty space inside each of the three
  cards; confirm the whole outlined rectangle selects the card. The cards are
  **Whichever works**, **On this Mac** (parakeet) and **AssemblyAI**. Confirm
  **Download**, the key field, and the links still perform their own actions:
  clicking the AssemblyAI key field must leave the selection alone.
- Confirm the **On this Mac** card says either **downloaded** or approximately
  600 MB. If the model is absent, start Download and verify that the progress
  bar and the megabyte count both advance without freezing the window.
- Confirm the AssemblyAI card always shows **Get a key**, that the link goes to
  `https://www.assemblyai.com/dashboard/signup`, and that a key already on disk
  is reported as **key found**.
- If an AssemblyAI key is available, paste it and verify **key works**. Do not
  put the key in `config.json`; it should land in `~/.config/amanu/keys/` with
  mode 0600. amanu never writes to the shared `~/.config/assemblyai/token`,
  though it still reads it.
- Open the **Meetings are mostly in** menu. Confirm it opens on **Detect
  automatically**, that English, Русский, Deutsch, Français and Español follow
  in that order behind a separator, and that the rest of the alphabet follows
  behind a second one. Every language is named in itself; no two-letter codes
  appear in the window.
- Pick a language, close Setup, reopen it, and verify the menu comes back on
  the same one and `config.json` holds its two-letter code. Picking **Detect
  automatically** must remove `transcription.language` rather than write an
  empty string.
- Confirm the line under the menu changes with the choice: nothing for English,
  the promise about English meetings for any other language, and the note about
  short or noisy meetings for **Detect automatically**.
- Confirm the **I want a live transcript during meetings** row sits under the
  language menu, says the model is 600 MB and downloads once, and reports
  **downloaded** when it is present.

## Summaries

- Confirm the Summaries switch is to the left of its heading, matching the
  automatic-recording row.
- Turn the switch off. Confirm `config.json` gains `summary.enabled: false`,
  that every card, radio, status line, segmented control and link in the
  section goes dim, and that **clicking a card while it is off changes
  nothing**. Turn it back on and confirm the key disappears again. This is the
  check that caught the switch being wired to nothing.
- Confirm the Claude Code card is selected for the default `auto` fallback
  chain — selecting it removes `summary.backend` rather than writing a name —
  and shows a visible `answers · <version>` status when Claude runs.
- Click the title, description, and empty space inside each summary card;
  confirm the entire outlined rectangle selects it without swallowing clicks on
  install links, key fields, or the provider selector.
- Confirm Codex is detected from either PATH or the copy bundled in
  ChatGPT.app, and its version status is visible.
- **By hand:** confirm **Install it** is visible only for a CLI that is
  missing. With both installed, neither link shows, and the only way to see the
  other state is to not have one.
- **By hand:** walk that link end to end — with a CLI missing, install it,
  reopen Setup, and confirm the row changes from `not here` to `answers · …`.
  Detection is cached for the life of the process and Setup drops the cache
  when it opens; before it did, the person who followed the link and came back
  was told `not here` until they restarted the app. Nothing automated covers
  this: `Tooling` searches real paths like `~/.local/bin` and takes no
  injection.
- On **My own key**, switch between Anthropic and OpenAI. Confirm the key
  placeholder changes between `sk-ant-…` and `sk-…`, and that **Get a key**
  changes between `console.anthropic.com/settings/keys` and
  `platform.openai.com/api-keys`.
- If keys are available, paste each one and verify **key works** without a paid
  completion. Confirm the files are mode 0600:

  ```sh
  stat -f '%Sp %N' ~/.config/anthropic/token ~/.config/openai/token
  ```

- Confirm Ollama is the slim row under the three cards — still selectable,
  still reporting whether it is installed and running, and naming up to two
  installed models. When Ollama is absent it reads **not here** and offers
  **Install Ollama** → `https://ollama.com/download/mac`; when present, the
  link is hidden.

## Audio retention

- Click both the checkbox square and the words **Keep the audio after
  transcribing**; confirm either target toggles the same checkbox, and that
  turning it off removes `keep_audio` rather than writing `false`.

**By hand** from here down — all of it needs a microphone, sound coming out of
the Mac, and a few minutes of waiting.

1. Leave **Keep the audio after transcribing** off. Make a short manual test
   recording with both microphone speech and Mac playback, then stop it.
2. Wait for `transcript.json` to appear. Confirm:
   - `transcript.json`, `transcript.md`, and the summary remain;
   - mic, system, and mixed audio files are gone;
   - `meta.json` contains `"audio_discarded": true`;
   - **Re-transcribe** is disabled for that session, and `amanu process` on it
     refuses with a reason rather than reporting `transcript: pending` and
     doing nothing.
3. Turn **Keep audio** on and make another short recording. After transcription,
   confirm:
   - one `audio.m4a` remains and the source `.caf` files are gone;
   - the M4A is materially smaller than the source PCM size reported in
     `transcribe.log`;
   - your microphone is audible only in the left channel and Mac playback only
     in the right channel;
   - **Re-transcribe** is enabled and successfully produces a new transcript
     from the archived channels, and `amanu process --again` does the same
     thing from the command line.
4. Optional failure-path check: temporarily select AssemblyAI without a usable
   key, record a few seconds, and confirm a failed transcript keeps the source
   audio. Restore the engine to **Whichever works** immediately afterwards.

## Reopening and restart behavior

- While the app is running, execute `amanu setup`. Confirm the existing app
  opens Setup, the command exits, and `pgrep` still shows one copy.
- Click **Later** or **Done**, quit and reopen the app, and confirm Setup does
  not open automatically again.
- Reopen Setup from both the menu-bar menu and the app menu. Both also carry
  **Check for updates…**, which is present only in a real bundle.
- **By hand:** make one final ordinary meeting test and verify auto-record,
  transcription, speaker naming, summary generation, and the recordings list
  still work.
