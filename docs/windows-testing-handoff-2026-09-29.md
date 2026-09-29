# Windows testing handoff — continue on the laptop

Written 29 September 2026, evening, for a new Claude session running **on the
Windows laptop itself** (the test machine), which picks up from a session on the
Mac that rewrote the app but could not run it. Remote Control messaging between
sessions stopped delivering, so everything needed is here.

Read first, in this order:

1. This file.
2. [`docs/windows-handoff-2026-09-29.md`](windows-handoff-2026-09-29.md) — the
   macOS audit's contracts and, at the end, the status of each of its 20 items.
3. [`docs/testing/windows-hardware-checklist.md`](testing/windows-hardware-checklist.md)
   — the full test list. This file says which parts are done.
4. `CLAUDE.md` and `AGENTS.md` at the repo root (commit-message voice, and that
   Windows checks must run on Windows).

## Where the code is

- Branch **`claude/windows-version-testing-11d877`** on github.com/gsamat/amanu,
  cloned at `C:\Users\samat\Documents\GitHub\amanu` (already on the branch; `git
  pull` first). Head when this was written: `061a34c` plus this document.
- `master` has only the CI workflow added (`6315fb8`), nothing else from the
  branch. Don't merge the branch without Samat.
- Code: `windows/src/Amanu.Core` (platform-neutral, tested),
  `windows/src/Amanu.App` (WPF shell), `windows/tests/Amanu.Core.Tests`.
- git on this machine is the copy inside GitHub Desktop; for a shell, prepend
  `%LOCALAPPDATA%\GitHubDesktop\app-3.6.6\resources\app\git\cmd` to `PATH`.
  `gh` is installed and logged in as gsamat. .NET SDK 10.0.401 is installed.

## What has been verified, and where

| Check | Where | Result |
|---|---|---|
| Core tests (110) | Mac, Windows laptop, GitHub windows-2025 runner | pass |
| Release build of the whole solution | Mac (cross), Windows laptop | 0 warnings, 0 errors |
| Installer + update feed, local `transcribe-cli.exe` compiled | GitHub Actions, runs 36602075343 (beta.3), 36606882820 (beta.4) | green |
| `transcribe-cli.exe --help` from the package | laptop | starts, exit 0, statically linked |
| Phase 1 GUI checks on **beta.3** | laptop, but the install was inside Claude's MSIX container (see below) | findings below, fixed in beta.4 |
| Phase 1 GUI checks on **beta.4**, all nine items | laptop, real install (Samat ran the Setup from Explorer) | pass — see "Phase 1 on beta.4" below |
| Phase 2.1–2.3: Parakeet download, a manual recording, local transcript, kept audio | laptop, beta.4 | works, with three bugs fixed for beta.6 and one open — see "Phase 2 on beta.4" |
| Signed beta.7 (`8723ccc`), including the fixes above | [Windows CI run 36618675823](https://github.com/gsamat/amanu/actions/runs/36618675823) | 110 tests pass; valid Fands Software LLC signatures and timestamps on the installer, payload and packaged Velopack helpers; no GitHub Release. Never installed on the laptop. |
| This branch's signed beta.6 (`45574de`, run 36617549549) | laptop, installed over beta.4 by Samat | installs, signatures valid, settings kept — but **the processing queue never starts on a second launch**; see "Beta.6 on the laptop". beta.7 has the same bug. |
| Signed beta.8 (`9739642`, run 36620569067) | laptop, installed over beta.6 by Samat | **installed and current.** The startup fix, UTF-8 transcripts and the "no model" wait all confirmed on the real recording — see "Beta.8 on the laptop" |
| Phase 2.4 (ten minutes, alignment across silence), phase 3 | — | **nothing yet** |

### Phase 1 on beta.4 (29 September, evening)

Installed for real at `C:\Users\samat\AppData\Local\Amanu\current\Amanu.exe`
(ProductVersion `0.6.0-beta.4+061a34c`); WMI confirmed the path.

- Setup opens at 860×648 logical px in the 1280×672 work area, top at y = 12;
  Settings fits too, with both tabs visible. Every beta.3 layout finding is fixed:
  the Download buttons line up, the `sk-…` field and the paste-key field keep their
  margin, Advanced's multiline fields show their right border, the switch is now
  "Watch which app holds the microphone", and the grey "No card chosen…" line sits
  above the summary cards.
- keep_audio writes `{"keep_audio": true}` and clearing it writes `{}`. Unchecking
  auto-record in the status window rewrote `config.json` and the Settings switch at
  once.
- "Later" opens the status window. Its × hides the window and the process stays;
  a tray left click brings it back. Samat checked the tray right-click menu (items
  and Windows 11 style, closes on an outside click) and "Later" with his own mouse.
- Starting "Amanu Beta" from Start while it ran brought the window forward (it was
  behind Explorer) and left one process — the beta.3 taskbar flash is gone.
- Real `HKCU\…\Run\Amanu` = `"…\Amanu\current\Amanu.exe" --background`, an
  `Amanu` Uninstall key exists, no `errors.log`, nothing from Amanu in the
  Application log.
- Screenshots: `C:\Users\samat\Documents\amanu-test-shots\beta4-*.jpg`.

Two things about the tooling, not the app. Computer use's synthetic click did not
press Setup's "Later" in three tries (UI Automation's Invoke did, and so did Samat's
mouse); every other button and switch took the first click. And one computer-use
scroll action is one wheel notch, whatever `scroll_amount` says.

The beta.3 run left its files inside Claude's container, where the shell reads them
*in preference to* the real ones — the shell would have shown beta.3's
`config.json` after beta.4 was installed. They were moved, not deleted, to
`…\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\_amanu-beta3-container-leftovers`.
To tell what is really on disk from inside the container, ask WMI
(`CIM_DataFile`, and `StdRegProv` under `HKEY_USERS\<sid>` for the registry).

### Phase 2 on beta.4 (29 September, evening)

- **Parakeet** downloaded from Settings in about fifteen seconds with the
  progress line moving (`models\parakeet-tdt-0.6b-v3-Q8_0.gguf.partial`, renamed
  when done). The network was not interrupted, so resuming is unverified.
- **Recording** `C:\Users\samat\Amanu Recordings\2026.09.29-2147`: manual, 142 s,
  Samat speaking Russian over an English interview Edge played through the
  speakers. `.recording.json` during, `meta.json` after (`stop_reason: manual`,
  `system_audio: "all"` — a manual recording with no call app records everything).
  `Get-ChildItem` showed both WAVs at 0 bytes until the stop: NTFS does not update
  a directory entry's size while the file is open, so this neither proves nor
  disproves that they grew. Next time read the size through a handle.
- **Transcription** by Parakeet took about 90 s; the WAVs were removed and
  `audio.m4a` kept: AAC, 48 kHz, stereo, 128 kbit/s, 141.87 s — the 48 kHz AAC
  fix holds. Left is the mic (Samat's voice where the call channel is digital
  silence), right the call. The mic is quiet: about −39 dBFS RMS while Samat
  speaks, −55 to −70 between. The video barely reaches the mic channel (−65 dB
  against −12), which looks like the Intel array's own echo cancellation — so
  cross-correlating the two gave only a weak 4.6 ms (0.18); the ten-minute test
  is still needed for alignment.
- **Bug, fixed for beta.6 (`ed41c18`):** every Cyrillic word in `transcript.md`
  and `transcript.json` was mojibake (UTF-8 read as Windows-1252). The CLI's
  pipes were read without `StandardOutputEncoding`, which for a windowless app
  means the ANSI code page. English was untouched, which is why no test caught it.
- **Bug, fixed for beta.6 (`1434c53`):** switches and cards save in `Click`, and
  UI Automation's Toggle/Select change them without one — the switch moves and
  nothing is written. Found when a UIA toggle of keep_audio left the switch on
  and `config.json` without it. Now a `ClickCheckBox`/`ClickRadioButton` routes
  both through `OnClick`.
- **Bug, fixed for beta.6 (`1d14c47`):** with summaries on `auto` and nothing
  installed, the only backend is an Ollama nobody chose; its "could not be
  reached" counted as an attempt, so after five one-minute retries the session
  would have been marked failed, blaming Ollama. It now counts as no model: the
  step waits (rescanned every ten minutes) and says "No model is set up…".
- **Fixed for beta.9, see below:** a local transcript was **one segment per side**
  (`them` 0:05–2:10, `me` 0:18), so `transcript.md` is two paragraphs, not a
  conversation. `transcribe-cli` returns a single segment for Parakeet with
  `--timestamps auto`, `segment` and `word` alike (checked on a TTS file with
  3-second pauses). macOS gets token timings and breaks on sentences and pauses
  (`ParakeetEngine.swift`). Options: cut each side at silences into pieces before
  the CLI (one `--batch` run, so the model loads once — this also bounds how
  much audio one call gets, which may matter for an hour-long meeting), or find a
  transcribe.cpp that exposes Parakeet's timings.

### Signing (29 September, evening)

Azure Artifact Signing is now working through the `windows-signing` environment
and tenant-only OIDC login. Samat explicitly allowed all branches in this
repository; forks do not match the immutable repository-ID Azure trust. The
service principal has Certificate Profile Signer access only on the production
Fands Software LLC profile.

Earlier runs encountered login and signing-module setup errors. Beta.5 proved
payload and installer signing; beta.6 additionally verified the generated
Velopack launcher and updater inside both packages. Neither included all of this
session's latest fixes. Use **0.6.0-beta.7**, built from `8723ccc`, instead:
[download the signed artifact](https://github.com/gsamat/amanu/actions/runs/36618675823/artifacts/11057746592).
The 110 core tests and signature checks passed on the Windows CI runner. This
does not establish GUI or recording behavior on the laptop; install and retest
there next. The artifact expires after 30 days and requires GitHub sign-in.

`upload_artifact` now defaults to **true** and refuses an unsigned downloadable
build; `publish_release` defaults to **false**. No GitHub Release or automatic
update was published. Use a fresh version for subsequent builds; do not replace
beta.7 with different application code.

Two agents building from two branches used the same numbers: there are two
different signed beta.6 builds (this branch's `45574de`, installed on the laptop,
and the signing branch's). Before dispatching, look at the latest runs on both
branches and take a number neither has used.

### Beta.6 on the laptop (29 September, late evening)

Samat installed this branch's beta.6 over beta.4; the real path, ProductVersion
`0.6.0-beta.6+45574de` and valid signatures on `Amanu.exe` and
`transcribe-cli.exe` checked out, and `config.json` was kept. "Done" in Setup
(never pressed before; it had only ever been "Later") closed it.

"Transcribe again → Parakeet" on `2026.09.29-2147` unpacked `audio.m4a` into
`.archive-mic.wav`/`.archive-system.wav`, wrote `transcribe.engine`, deleted the
old transcript — and nothing more happened for four minutes: no CLI process, and
the Recordings list still said "done (parakeet)". `errors.log` had the reason,
an unobserved `ArgumentNullException` from `AnalyticsService.StartAsync`.
`AtomicFiles.WriteJsonAsync` writes camelCase and the analytics files were read
back with System.Text.Json's defaults, PascalCase and case-sensitive, so
`analytics.json` read as `Id = null, VersionsSeen = null` (checked against the
real file). The first launch of an installation has no file and never sees it;
**every later launch threw in `AmanuRuntime.StartAsync` before
`processing.Start()`, the call watcher and the rescans**, and the exception
filter there only caught I/O and JSON errors. Fixed in `cdc86b9`: the files are
read with the options they are written with, a half-empty identity counts as none,
and whatever statistics throw is logged and passed over. beta.7 predates it.

Also seen, not yet looked into: after "Transcribe again" the Recordings list kept
showing the old status. It may only be that no processing event was published
because the queue was not running; re-check on beta.8.

### Beta.8 on the laptop (29 September, late evening)

Samat installed beta.8 over beta.6: real path, ProductVersion
`0.6.0-beta.8+9739642`, installer signed and timestamped. This was not the
installation's first launch, so it exercised the fix:

- `analytics.json` kept its id and gained `0.6.0-beta.8` in `versionsSeen`; no
  new `errors.log` (beta.6's is kept as `errors.beta6.log`).
- The queue started and, within 30 s, finished the re-transcription beta.6 had
  abandoned (it resumed from the `.archive-*.wav` files and `transcribe.engine`).
- **The Russian side is correct Cyrillic** in `transcript.md` and in the
  Recordings window's Transcript tab.
- Names and summary are deferred with "No model is set up for this: install Claude
  Code or Codex, add an API key, or run Ollama.", every attempt counter at 0, and
  the Recordings list says "waiting" rather than "failed".
- Screenshots: `C:\Users\samat\Documents\amanu-test-shots\beta8-*.jpg`.

Not fixed: the Transcript tab shows the Markdown source (`**[0:05] them:**`)
rather than rendering it; still one segment per side (see Phase 2).

### One segment per side — fixed for beta.9 (`7cab7d6`)

Samat asked for it to work as on the Mac. There, Parakeet's token timings are
grouped into words and the words into segments: a break at `.`, `?` or `!`, before
a pause of more than a second, and at sixty words (`ParakeetEngine.swift`).
transcribe.cpp computes the same word timings; its `--batch-jsonl` just leaves
them out (v0.1.3 and v0.2.4 alike), while its plain output for a single file
prints `words: N` and N lines of `[t0 -> t1] word`. So Parakeet now runs once per
track with `-q --timestamps word <file>`, `LocalCliWords` reads that block and
groups it by the macOS rule, and a track with text but no readable words still
keeps its text as one paragraph. Whisper and GigaAM keep the batch JSONL path
(on the Mac they are cut by fixed-length chunks instead; neither was downloaded
here to check). The CLI also reports `max audio: unbounded (long audio chunked
internally)`, so an hour-long track is not a concern for it.

Run on both sides of `2026.09.29-2147` through the new code, the transcript
interleaves: `[0:17] them: I'm guessing` / `[0:20] me: …` / `[0:30] them: I can
say that it did not top breaking bad.` — one sentence of the video split exactly
around Samat's turn while he had it paused. That is the far side's timeline
surviving 10–20 s pauses. It does not settle checklist §4.2: nothing records
whether loopback stopped delivering during those pauses (so `TrackWriter` padded
them) or kept delivering silent packets, and §4.2's case is five minutes of
silence.

Small notes, not fixed: Advanced puts "Run after each session" under the
"Interface" heading, and the interface language says it "takes effect at the next
launch" while the release notes promise no restarts.

### What beta.3's first run found (all fixed in beta.4, unverified)

- Setup and Settings windows (860×737) were taller than the work area (1280×672
  logical at 150% on this 1920×1080 panel) and opened at y = −74, title bar off
  screen. Now sized by `Ui.FitToWorkArea`.
- Starting Amanu a second time flashed the taskbar instead of bringing the window
  forward. The second instance now calls `AllowSetForegroundWindow(-1)` before
  ringing the running one.
- "Download…" buttons not aligned across cards; the `sk-…` field flush against
  its card's edge; Advanced's multiline fields clipped on the right; the Call apps
  and Anthropic-model help contradicting their placeholders; the Advanced
  `mic_activity` switch looking like the auto-record switch (now "Watch which app
  holds the microphone"); no hint that summaries on `auto` pick no card (now a grey
  line above the cards).

Passed on beta.3 (worth re-checking quickly on beta.4): section order and wording
of the setup form; keep_audio writes `{"keep_audio": true}` and clearing it writes
`{}`; "Later" shows the status window; a tray left-click restores it; Settings has
Setup and Advanced tabs with help lines and grey defaults; unchecking auto-record in
the status window updates the Setup tab and `config.json` at once; a second launch
leaves one process. No `errors.log`, no Application-log errors.

## Things learned about this machine — read before doing anything

1. **Don't launch the installer or Amanu from a Claude session's shell.** The
   Claude desktop app is an MSIX package; processes it starts run inside its
   container, so Velopack installed into
   `C:\Users\samat\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\{Amanu, Amanu Data}`,
   and Amanu ran under Claude's package identity (its microphone consent was
   Claude's). The results were not clean.
2. **Launching through `explorer.exe <file>` to escape the container was denied**
   by the session's permission layer as a sandbox bypass. Don't route around that
   by any other means. **Samat double-clicks
   `Amanu-beta-Setup.exe` in Explorer himself**, and starts "Amanu Beta" from the
   Start menu when a check needs a relaunch. (Or Samat can change the session's
   permission mode — his decision.)
3. **Always check which copy is running** with WMI, which shows the real path:
   `Get-CimInstance Win32_Process -Filter "Name='Amanu.exe'" | Select ProcessId, ExecutablePath`.
   The real one is `C:\Users\samat\AppData\Local\Amanu\current\Amanu.exe`. Stop any
   copy under `Packages\`. The shell's `%LOCALAPPDATA%` may be the virtualized view;
   use `C:\Users\samat\AppData\Local\...` literally and say which path you read.
4. **Leftovers from the containerized beta.3** may exist under Claude's LocalCache
   and a stale "Amanu Beta" Start-menu shortcut and `Run` value may point there.
   Installing beta.4 for real should overwrite both; check.
5. **Computer use gets "click" tier on Explorer and the taskbar**: left clicks
   only — no right-click, typing, keys or double-click there. The tray right-click
   needs Samat. Amanu's own windows get full tier (request access to Amanu.exe).
   Elevated windows (UAC) can't be driven at all.
6. **Audio:** Samat is at the console now, so the real devices are active —
   "Microphone Array (Intel® Smart Sound Technology)" and "Speakers (Realtek(R)
   Audio)". Over RDP they were replaced by "Remote Audio". No headset or Bluetooth
   device is paired. Installed: new Teams (MSTeams) and Edge 154. No Zoom, Telegram,
   Chrome, Claude Code CLI or Codex CLI.
7. Remote Control messages between sessions arrived unreliably and seemed to wait
   for approval in the receiving session. Work in one session.

## The installers

- Installed on the laptop: beta.8 from
  `C:\Users\samat\AppData\Local\Temp\amanu-beta8\Amanu-Windows-0.6.0-beta.8-x64\Amanu-beta-Setup.exe`
  (signed, per-user, no UAC; ProductVersion 0.6.0-beta.8, commit `9739642`).
  Earlier installers are beside it in `…\Temp\amanu-beta6` and `…\Temp\amanu-beta4`.
- To build a new one after a fix: bump `<Version>` in
  `windows/src/Amanu.App/Amanu.App.csproj` (and the default in
  `windows/scripts/Build-Beta.ps1`, `windows/README.md`,
  `.github/workflows/windows-beta.yml`), commit, push, then
  `gh workflow run windows-beta.yml --repo gsamat/amanu --ref claude/windows-version-testing-11d877 -f version=0.6.0-beta.N -f publish_release=false -f upload_artifact=true`
  (artifact upload is on by default, and requires signing),
  `gh run watch <id> --repo gsamat/amanu --exit-status`,
  `gh run download <id> --repo gsamat/amanu -D $env:TEMP\amanu-betaN`. About five
  minutes. Don't set `publish_release=true` (a public prerelease) without Samat.
- A quicker loop for UI-only changes: `dotnet build windows\Amanu.Windows.slnx -c Release`
  gives `windows\src\Amanu.App\bin\Release\net10.0-windows10.0.26100.0\Amanu.exe`,
  but it has no local transcription CLI, isn't the installed copy, and launching
  it from the shell puts it in the container too — so Samat starts it from
  Explorer. Quit the installed Amanu first (single-instance).

## What to do next

Save screenshots as PNGs in `C:\Users\samat\Documents\amanu-test-shots\` with a
`beta4-` prefix, so Samat can look too.

### Phase 1 again, on a real beta.4 install — done, all pass (see above)

1. Samat double-clicks the beta.4 Setup. Confirm the real path (item 3 above).
2. Setup window: its `GetWindowRect` fits in 672 logical px with the title bar on
   screen; scroll through and check the fixes listed above.
3. Keep audio on and off → `C:\Users\samat\AppData\Local\Amanu Data\config.json`.
4. "Later" → status window. Tray: left click restores; Samat right-clicks → the
   menu (Windows 11 style) lists state, Start recording, Pause, Record meetings
   automatically ✓, Show Amanu window, Open recordings folder, Manage recordings…,
   Import…, Settings…, Setup…, Check for updates…, About Amanu, Quit Amanu; it
   closes on an outside click.
5. Settings: fits the screen, both tabs visible, Advanced rows unclipped.
6. Auto-record toggled in the status window → tray tick and Setup switch follow.
7. Samat launches from Start while it runs → one process, window comes forward.
8. × on the status window → process stays, tray brings it back.
9. `HKCU\...\Run` value `Amanu` → real exe with `--background`; no `errors.log`;
   no Application-log errors.

### Phase 2: a real recording, transcribed locally

1. In Setup, turn "On this computer" on with Parakeet (download ~740 MB; watch the
   progress line; interrupt the network briefly to see it resume if convenient).
2. Manual recording, about a minute: Samat speaks while Edge plays a spoken video
   through the speakers. During it: `mic.wav` and `system.wav` both grow in the
   session folder (`C:\Users\samat\Amanu Recordings\<date> …`), `.recording.json`
   exists. Stop: `meta.json` written, marker gone.
3. The session transcribes: `transcript.md` with `me` and `them` lines, the
   Recordings window shows "done (parakeet)". With keep_audio on, only
   `audio.m4a` is left (stereo, mic left, call right — this is the first real test
   of the 48 kHz AAC fix); with it off, no audio.
4. **Alignment across silence** (checklist §4.2): ten minutes with the far side
   silent in the middle; the kept audio's two channels stay in step.
5. Summaries: no Claude Code, Codex or key on this machine, so with summaries on
   the session waits ("no model…"); that is correct. If Samat pastes a key
   himself, re-check. Don't type keys.

### Phase 3: automatic recording and robustness

Teams (new) and a meeting in Edge: auto-start after the start delay, stop after
the mic is released; a 20-second join is discarded; kill Amanu mid-recording and
restart (recovery, header repair); sleep while recording; `system_audio = all`;
live transcript. See checklist §4 and §6–7 for the rest.

## When something is wrong

- Crash or error: `C:\Users\samat\AppData\Local\Amanu Data\errors.log`, the
  session folder's `transcribe.log` and `processing.json`, and the Application
  event log.
- Fix it in the branch, build and run the core tests
  (`dotnet test windows\tests\Amanu.Core.Tests`), commit in the repo's voice (one
  prose sentence, no prefixes; read `git log` first), push, rebuild the installer
  through CI as above, and have Samat install the new one.
- Record what was verified and on which build by updating the status table in
  this file, so the next session knows where things stand.
