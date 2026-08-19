# Setup window: manual verification

Last run 19 August 2026, against `Amanu.app` 0.2.0; the settings-window
section below was added when the form moved into Settings and has not been run
against a build yet. Most of it can be driven
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

`docs/testing/window-shots.md` is the other half of this: it renders both
windows to PNG files and lists every view's frame, which answers the questions
about spacing, borders and appearance without a person squinting at a screen.
Take the shots first — several items below are quicker to settle from a picture
than from the running application.

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

- Look down the list first: the rows that are down to one line must be the same
  height and evenly spaced, whether or not they still carry a button. The gap
  above **Calendar** used to be half again the others, because the System audio
  row above it keeps **Test again** and came out eight points taller for it.

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

The section is two switches and a pair of provider cards, not a row of
mutually exclusive cards. Having both switches on *is* the fallback — the
cloud when it answers, this Mac when it doesn't — so there is no third card
for it any more.

- Confirm both switches on removes `transcription.engine` from `config.json`
  rather than writing `auto`, and that switching only the cloud off writes
  `"engine": "parakeet"` (and only the Mac off writes the provider's name).
- Turn both off. Confirm `config.json` gains `transcription.enabled: false`
  and that `engine` is left alone, so turning one back on remembers the
  provider.
- Confirm the **AssemblyAI** and **OpenAI** cards are on screen even while
  **In the cloud** is off, each showing its price per hour, and that the card
  for a key already on disk says **key works**.
- With no key for the chosen provider, switch **In the cloud** on. Confirm the
  switch stays off, the key field takes focus, and the status says a key is
  needed. A switch that reads "on" while every transcript fails with HTTP 401
  is the defect this behaviour exists to prevent.
- Paste a working key and confirm the switch turns itself on, the card says
  **key works**, and the key lands in `~/.config/amanu/keys/` with mode 0600 —
  never in `config.json`. amanu never writes to the shared
  `~/.config/assemblyai/token`, though it still reads it.
- Paste a *wrong* key over a working one and confirm the saved key is
  untouched and the status says so.
- Submit a key with **Return** rather than by clicking away, and confirm the
  window stays open long enough to say what happened — `checking…`, then
  `key works` or `that key was refused`. Return used to reach **Done**, which
  closed the window on the keystroke that submitted the key: the check
  finished into a window nobody could see, and the only way to learn whether
  the key was accepted was to open Setup again. Return anywhere *else* in the
  window should still mean Done.
- With both keys present, click the other provider's card. Confirm the cloud
  switch stays on, `transcription.cloud` changes, and — for a provider with no
  key — that clicking its card leaves the working provider in force and only
  opens the key field.
- Confirm **Get a key** appears on a card without a key and points at
  `https://www.assemblyai.com/dashboard/signup` and
  `https://platform.openai.com/api-keys` respectively.
- Switch **On this Mac** on with the model absent. Confirm the download starts
  from the switch alone — there is no Download button — and that the progress
  bar and the megabyte count both advance without freezing the window, and
  that the bar reaches its end rather than stopping short of it: it counts
  towards 460 MB, the size parakeet actually is on disk. With the model
  present the row says **downloaded**.
- With **On this Mac** on, the cloud switch on too, and the model absent,
  reopen Setup: the footer must name `parakeet` and the button must offer
  **Download parakeet**. Both switches on writes no engine to the config at
  all, so a window that reads the engine name rather than the switch goes
  quiet here and promises that everything amanu needs is granted.
- **By hand, Intel:** confirm **On this Mac** is visible but disabled and says
  it needs Apple Silicon, rather than being missing.
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
- Submit the summary key with **Return** and confirm the window stays open and
  reports the outcome — the same defect lived in this field, under the same
  default button, and was fixed in the same place.
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

- Click both the switch and the words **Keep the audio after transcribing**;
  confirm either target toggles the same switch, and that turning it off
  removes `keep_audio` rather than writing `false`. It is a switch like every
  other yes/no in the window, and its symbol sits in the same column as the
  folder above it.

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
4. Optional failure-path check: temporarily switch **On this Mac** off and put
   an unusable key in place of the working one, record a few seconds, and
   confirm a failed transcript keeps the source audio. Switch the Mac back on
   and restore the key immediately afterwards.

## The settings window shows the same form

The form on this list is also the first tab of **Settings** (⌘,). It is one
`SetupForm`, not two, so everything above holds there as well; what is worth
checking by hand is only the seam between them.

- Open Settings and confirm the **Setup** tab is selected, is scrolled to the
  top — the Access list, not the middle of it — and shows the same rows,
  switches, cards and machine-read statuses as the Setup window.
- In **Advanced**, confirm every empty field shows its default in grey and
  nothing is truncated at the right edge of the field.
- Change something in **Advanced** that the Setup tab also shows —
  `keep_audio`, or `transcription.cloud` — switch back, and confirm the Setup
  tab already agrees. It is redrawn on every write rather than when reopened.
- Change the same setting on the Setup tab and confirm `config.json` says so.
- **Open Settings and Setup side by side**, so both are visible at once, and
  change the same setting in each in turn: the cloud provider, **Keep the
  audio**, the meeting language, **On this Mac**. Confirm the other window
  follows *immediately*, without being clicked or brought forward. This is the
  one that used to fail — the file was written correctly and the window nobody
  had touched kept the old answer until it was reopened.
- With both open, turn the live transcript on in one and confirm the status
  window's own live switch follows too, and the other form with it.
- Automated tests cover the listening half of this — every open form redraws
  when told the file changed. That a write *announces* itself is only checked
  here, because writing the config file of whoever runs the suite is not
  something the tests may do.
- Confirm the Setup tab has no **Later** or **Done**: those belong to the
  first run, and setup is marked completed by that window, not by this one.

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
