# Windows handoff — after the macOS audit of 0.4.27

Written 29 September 2026 for the next session working on `windows/`. It says
what the macOS side just learned the hard way, so the Windows app can check
itself against the same failure classes rather than rediscover them.

## Where things stand

- **macOS 0.4.27 is published** (GitHub release, `amanu.me/appcast.xml`,
  landing links). `origin/master` is at `79e3936 Publish amanu 0.4.27`. It
  contains a full audit of the macOS app and about 90 commits of fixes; the
  trail is `git log 69e8170..79e3936`.
- **The Windows work is not committed.** It exists only as uncommitted files
  in the main checkout (`/Users/samat/Documents/проекты/amanu`):
  - `windows/` — the C#/.NET 10 WPF solution (≈4.6k lines in `src/`, tests
    in `tests/Amanu.Core.Tests`), plus `windows/.tools/` (vpk) and
    `windows/artifacts/release-beta2/` (a built 0.6.0-beta.2 feed);
  - `docs/specs/2026-09-20-windows-app-design.md`, `windows/README.md`,
    `windows/BETA.md`, `docs/windows-beta-requesters.md`;
  - `.github/workflows/windows-beta.yml`, `landing/tests/check_short_links.py`,
    `landing/win.exe`;
  - modified `.gitignore` (ignores `bin/`, `obj/`, `.vs/`, `windows/.tools/`,
    `windows/artifacts/`) and `landing/deploy/nginx/amanu.conf` (adds the
    `/win.exe` redirect to the 0.6.0-beta.2 installer, and a `/zzzsamat`
    redirect to a Zoom room that probably should not be in the public config).
- A worktree does **not** carry uncommitted files. Either work in the main
  checkout, or first commit the Windows work to a branch (e.g.
  `windows/beta`) and work in a worktree from it. Committing first is better:
  none of it is recoverable today if the checkout is cleaned.
- Per `AGENTS.md`, Windows builds, tests and GUI checks run on the Windows
  host connected to Codex. A Claude session on the Mac cannot reach it; it can
  read and edit code, and run the core tests only if `Amanu.Core.Tests` builds
  on macOS (`Amanu.Core` is a plain .NET library, so it may).

## What the macOS audit found, and what Windows should check

Each item is a failure class that existed on macOS, with the fixed contract.
"Windows today" is a first glance at the code, not a verified finding.

### Privacy — where meeting content may go

1. **Speaker naming must follow the summary backend.** macOS had
   `speaker_names.backend = auto` independent of the summary's choice, so
   picking Ollama (or turning summaries off) still sent transcripts to Claude
   or OpenAI for naming. Fixed contract: `speaker_names.backend` defaults to
   `summary` — wherever summaries go, and nowhere when they are off; an
   explicit value is a choice for naming alone; `none` asks no model. One
   place decides egress (`Sources/amanu/Summary/MeetingEgress.swift`).
   *Windows today:* `SpeakerNameSettings.Backend` defaults to `"auto"`
   (`windows/src/Amanu.Core/Configuration/AppSettings.cs:149`) — very likely
   the same leak.
2. **A per-session engine choice must be honoured even while a queue is
   draining**, and a cloud→local fallback applies only to the session that
   failed. macOS reused one prepared engine for the whole queue, so
   "retranscribe with Whisper" on a sensitive meeting went to AssemblyAI.
   See `Sources/amanu/Transcription/EngineResolver.swift`.
3. **Keys stay with their service.** The OpenAI transcription key and a key
   for an OpenAI-compatible summary server (OpenRouter, Groq) are separate
   slots; the OpenAI key is only ever sent to api.openai.com, or as a last
   resort to a server on this machine. Check `SecretStore.cs` and how the
   summary's base URL picks a key.
4. **A CLI model runner gets no tools.** If Windows ever shells out to
   `claude` or `codex`, use the macOS argument lists in
   `Sources/amanu/Summary/LLMBackend.swift` (`--tools ""`,
   `--setting-sources ""`, MCP disabled). A transcript is untrusted input.

### Configuration

5. **An unparseable config must not reset the user's choices.** macOS used to
   fall back to defaults (analytics on, engine auto → cloud) and then wrote
   an empty object over the file on the next click. Fixed contract: keep the
   last good settings in memory, refuse to write over the broken file, hold
   transcription and summaries, show the problem, recover when it is fixed;
   if nothing was ever read, be conservative (auto-record off, no egress).
   *Windows today:* `AppSettingsStore.Load` quarantines the bad file and saves
   defaults (`AppSettingsStore.cs:22-31`). Nothing is lost on disk, but the
   app silently switches to defaults — analytics back on, backends `auto`,
   recordings folder reset. Decide whether that is acceptable; the macOS
   answer was no.
6. **Settings changed at runtime take effect at runtime** (auto-record switch,
   recordings folder, live transcript) through one applier, and a menu or tray
   toggle writes the same setting the Settings window shows.

### Recording

7. **Auto-record must not re-arm behind its own backstop.** After a
   max-duration or silence stop, macOS started a new recording five seconds
   later because the call app still held the mic. The fix is an explicit
   state machine: after an automatic stop, wait for the mic to be released.
   *Windows:* check `AutoRecordPolicy.cs:111` and `:151` — the same shape.
8. **A failing start backs off** (30 s doubling to 10 min), removes the empty
   folder it created, and replaces its notification rather than stacking them.
9. **The duration ceiling applies to every recording**, including manual
   ones and while auto-record is off.
10. **Never delete the "recording in progress" marker before `meta.json` is
    durably written**; on a write failure keep the marker so recovery adopts
    the session.
11. **Archiving must keep both channels** of a stereo call track (macOS kept
    only the left one), must fail rather than zero-fill on a mid-file read
    error, and must amend `meta.json` under a lock rather than write back a
    copy read minutes earlier.
12. **Sleep ends a recording cleanly**, and gap padding after a device change
    is capped and kept off the audio callback.

### Transcription and post-processing

13. **Re-transcription discards provider caches** (and marks the old summary
    stale rather than deleting it), or a corrected language returns the old
    text.
14. **Environmental failures do not use up a session's attempts**: a model
    download, a missing key, no network. Only failures of the recording
    itself count toward the three-attempt limit.
15. **A missing or empty track is a silent side**, not a failure of the whole
    session, as long as another track has audio.
16. **Optional pre-processing degrades, never blocks**: if echo cancellation
    fails, transcribe the raw tracks and record why.
17. **Summaries give up eventually.** Defer while a backend is only
    unreachable, but cap real attempts (macOS: 5) so a transcript is not
    re-sent to every backend at every launch.
18. **`on_stop` fires once**, after names and summary (or after they are
    definitively skipped), never while the config is unreadable.
    *Windows:* `ProcessingCoordinator.cs:175` and `:256` both call
    `RunHookAsync` — check it cannot fire twice for one session.

### Tests

19. **Tests must not see the developer's real settings, keys or models.** On
    macOS every test reads config through a sandboxed home
    (`Sources/amanu/Home.swift`, `Tests/amanuTests/Support/TestHome.swift`),
    and a guard test proves no test can reach an LLM. The Windows tests
    already use `TemporaryDirectory`; check nothing reads
    `%LOCALAPPDATA%\Amanu` or Credential Manager.
20. **Test the failure paths, not only the happy path**: invalid config,
    concurrent claims, a track that never delivered audio, HTTP 401/429/5xx,
    a download that fails halfway.

## Suggested order

1. Commit the Windows work to its own branch; move the `/zzzsamat` redirect
   out of the public nginx config if it is personal.
2. Items 1–5 (privacy and config) — they decide what leaves the machine.
3. Items 7–12 on the Windows host, with a real recording.
4. Items 13–18, then 19–20 alongside each fix.

## Pointers

- macOS contracts as implemented: `README.md` (config reference, `on_stop`
  contract) and `docs/pitfalls.md` (including "What has never been
  verified").
- The audit itself was done in a chat session and is not saved as a
  document; the commit messages from `69e8170` onward explain each fix.

## Status after the 0.6.0-beta.3 rework (29 September 2026)

Done in code on the Mac, compiled with `EnableWindowsTargeting` and covered by
the core tests where the logic lives in `Amanu.Core`; **none of it has run on
Windows yet** — `docs/testing/windows-hardware-checklist.md` is the list to go
through there.

| # | Status |
|---|---|
| 1 | `MeetingEgress` in Core: `speaker_names.backend` defaults to `summary`, `none` asks no model. Tested. |
| 2 | `EngineResolver` plans per session; `transcribe.engine` in the session folder pins a re-transcription's engine; cloud→local fallback only for that session. A named local engine never uploads (the old `EngineSelector` did). Tested. |
| 3 | `KeyRouting`: OpenAI key only to api.openai.com or this computer; `openai-compatible` slot for other servers; http only on this computer. Tested. |
| 4 | `CliArguments` mirror the macOS lists (claude via `--system-prompt-file`, see the checklist; codex with MCP servers switched off by name). Tested. |
| 5 | `AppSettingsStore`: an unreadable file is never replaced; last good settings in memory, conservative ones if never read; transcription waits; `FileSystemWatcher` recovers. Unusable single values fall back and are named. Tested. |
| 6 | `AmanuRuntime.Update` is the one applier; no Save button anywhere. |
| 7 | `AutoRecordPolicy` is an explicit state machine (watching / recording / standing down / backing off). Tested. |
| 8 | Backoff 30 s doubling to 10 min; a failed start leaves no folder; one notification at a time. Tested (policy and coordinator). |
| 9 | Ceiling enforced on its own clock for every recording. Tested. |
| 10 | Marker kept when `meta.json` cannot be written; the session stays out of the queue for recovery. |
| 11 | Archive is aligned stereo, both channels of the call mixed, a missing side silent. No read-modify-write of `meta.json` after the fact. |
| 12 | Sleep and sign-out stop the recording; loopback silence and device gaps are padded from QPC timestamps, capped at 30 min per gap; WAV headers flushed every 5 s and repaired on recovery. **Needs the hardware check most.** |
| 13 | Re-transcription clears `.cache-*` and the AssemblyAI job file, marks `summary.stale`. |
| 14 | `ProcessingFailure` kinds: environmental and transient failures use no attempts. |
| 15 | A track without samples is a silent side. |
| 16 | No offline echo cancellation exists on Windows, so the setting was removed rather than left to lie; the transcript echo filter remains. |
| 17 | Names and summaries give up after five tries that reached a model. |
| 18 | `on_stop` runs once, recorded in `processing.json` (`hook_ran`), never while the config is unreadable. |
| 19 | Core tests use temporary directories only; nothing in Core reads `%LOCALAPPDATA%` or Credential Manager. |
| 20 | Failure paths tested in Core: invalid config, wrong-kind values, failing starts, short joins, ceiling, HTTP 401/429/5xx and no network. The processing coordinator itself lives in the WPF project and has no tests. |

The config keys now follow the macOS names (`transcript_echo_filter`,
`summary.model`, `summary.ollama_base_url`, `transcription.openai.model`, …).
No tester had the beta, so nothing migrates old Windows keys.
