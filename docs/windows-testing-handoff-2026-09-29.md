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
| Any recording, transcription, summary | — | **nothing yet** |

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

- beta.4 (current): `C:\Users\samat\AppData\Local\Temp\amanu-beta4\Amanu-Windows-0.6.0-beta.4-x64\Amanu-beta-Setup.exe`
  (unsigned, per-user, no UAC; ProductVersion 0.6.0-beta.4, commit `061a34c`).
- To build a new one after a fix: bump `<Version>` in
  `windows/src/Amanu.App/Amanu.App.csproj` (and the default in
  `windows/scripts/Build-Beta.ps1`, `windows/README.md`,
  `.github/workflows/windows-beta.yml`), commit, push, then
  `gh workflow run windows-beta.yml --repo gsamat/amanu --ref claude/windows-version-testing-11d877 -f version=0.6.0-beta.N -f publish_release=false`,
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
