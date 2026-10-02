# Amanu

**Records and transcribes online meetings. Automatically.**

Amanu is a free, open-source meeting recorder for macOS and Windows. It works
with Zoom, Google Meet, Telegram, WhatsApp, and other call apps without sending
a bot into the meeting. It starts and stops recording on its own, separates
speakers, writes a detailed summary, and keeps the complete record in an ordinary folder
on your computer.

[Website](https://amanu.me/) ·
[Download for macOS](https://github.com/gsamat/amanu/releases/download/v0.6.4/amanu-v0.6.4-macos-universal.dmg) ·
[Download for Windows](https://github.com/gsamat/amanu/releases/download/windows-v0.6.4/Amanu-0.6.4-Setup.exe) ·
[MIT license](LICENSE)

| | macOS | Windows |
| --- | --- | --- |
| Requirements | macOS 14.2 or later; universal app | Windows 11 24H2 or later, x64 |
| Signing | Apple Developer ID, notarized | Microsoft Artifact Signing, Fands Software LLC |
| Recording | Automatic and manual; microphone and call audio | Automatic and manual; microphone and call audio |
| Local transcription | Parakeet, Whisper, GigaAM on Apple Silicon | Parakeet, Whisper, GigaAM on x64 |
| Cloud transcription | AssemblyAI, OpenAI, ElevenLabs | AssemblyAI, OpenAI, ElevenLabs |
| Summaries | Claude Code, Codex, Anthropic, OpenAI, OpenAI-compatible, Ollama | Claude Code, Codex, Anthropic, OpenAI, OpenAI-compatible, Ollama |
| Live transcript | Separate local streaming model | Separate local streaming model |
| Calendar context | Optional | No calendar integration |

macOS and Windows share version **0.6.4**, read from the root `VERSION` file.
Their release tags and automatic update feeds remain separate.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="landing/assets/shots/en/status-recording-dark.png?v=36e030d5a322">
  <img alt="Amanu for macOS recording a meeting and showing a live transcript" src="landing/assets/shots/en/status-recording-light.png?v=8c372c3274ad" width="320">
</picture>

*Recording window on macOS.*

## What Amanu does

- **Records meetings automatically.** Amanu notices when a call app is using
  the microphone, adds optional calendar context on macOS, and stops when
  the call ends. Manual controls are always there too.
- **Produces a speaker-attributed transcript.** Your microphone and the other
  side of the call remain distinct, with diarization inside each side when the
  transcription engine supports it.
- **Puts names to voices.** Amanu uses evidence in the transcript and, on
  macOS, optional calendar participants. It accepts a name only when
  confidence is high. You can manually correct the rest.
- **Writes a detailed summary.** The result covers the topic, key points,
  decisions, action items, and open questions. Amanu uses the models you choose
  instead of imposing a budget model of its own.
- **Shows its work.** The macOS status window, menu bar, and Dock icon, or the
  Windows recording window and system tray, make it clear when a recording is
  running. An optional live transcript streams locally while you speak,
  independently of the engine chosen for the final transcript.
- **Keeps one folder per meeting.** Audio, transcript, speaker names, summary,
  metadata, and processing logs are ordinary files that you own and can give
  to other tools.

## Local when you want it, powerful when you need it

Recording always happens on your computer. Amanu can also transcribe and
summarize a meeting without sending its contents anywhere:

- Parakeet, Whisper, and GigaAM provide local transcription. macOS local
  transcription requires Apple Silicon; the Windows app bundles its x64
  runtime and downloads the selected model from Settings.
- The optional live transcript runs locally.
- Ollama can write summaries locally when its Base URL is localhost/loopback.

Cloud models are available when quality or convenience matters more than
staying entirely offline. On both platforms, AssemblyAI, OpenAI, and ElevenLabs
can transcribe; Claude Code, Codex, Anthropic, and OpenAI can write summaries.
Within each model family, Amanu prefers an existing CLI subscription to the corresponding metered API
key and falls through to the next configured backend when a subscription is
exhausted.

Local models must be downloaded before offline use. Speaker naming follows
summaries by default; choose Ollama for summaries and keep naming on
`summary` for fully local processing. Claude Code and Codex use a signed-in
subscription and still send the transcript to their provider. On Windows,
Settings can detect their standalone tools and supported desktop-bundled
CLIs, including Claude Desktop from the Microsoft Store. A desktop app being
signed in does not always sign its CLI in; use the Sign in control in Settings.

On macOS 0.6.1, Codex uses its own configured model; `summary.openai_model`
applies only to the OpenAI API. The Windows model-setting behavior is
described below.

There is no Amanu account and no hosted meeting library. No meeting content
leaves your computer when all transcription, summary, and speaker-naming
backends are configured to run locally. Cloud and CLI summary backends receive
the transcript plus available meeting context such as its title and, on macOS,
calendar participants. Ollama keeps that work on your computer when it is
configured with a localhost/loopback Base URL. The data-flow description for
both platforms is in the [privacy notice](PRIVACY.md).
Work that cannot run without a network is marked as deferred and
resumed later instead of being silently dropped. A summary or naming pass that
keeps reaching a model without getting an answer stops after five tries, until its
settings, keys or backends change.

Anonymous product-usage reporting is enabled by default with a random install
UUID. The last control in first-run setup, and the same control in Settings,
turns it off. Recordings, transcripts, summaries, calendar contents, names,
paths, keys, and error text are never included. The complete event and field
list is public in [What Amanu sends](docs/analytics.md).

## What a meeting leaves behind

A typical retained session on macOS looks like this; Windows uses the same
artifact names under `%USERPROFILE%\Amanu Recordings`:

```text
~/Recordings/2026.09.02-1400 Weekly sync/
├── audio.m4a          # optional: microphone left, call audio right
├── transcript.md      # readable transcript with speaker names
├── transcript.json    # timed segments and engine provenance
├── speakers.json      # names, confidence, and supporting evidence
├── summary.md
├── meta.json          # timing, devices, trigger, and processing state
└── transcribe.log
```

Audio can be discarded automatically after a successful transcript. If
transcription fails, Amanu keeps the source recording so it can be tried again.
The recordings window shows what is complete, pending, or failed for every
session.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="landing/assets/shots/en/recordings-dark.png?v=5653cdc661de">
  <img alt="Amanu for macOS meeting library with an open transcript" width="860" src="landing/assets/shots/en/recordings-light.png?v=0174ba514607">
</picture>

*Meeting library on macOS.*

## Why Amanu is built this way

The less visible parts of Amanu come from failures measured on real calls, not
from an idealized recording pipeline.

- **No bot, virtual audio device, or kernel extension.** A Core Audio process
  tap on macOS, or WASAPI process loopback on Windows, captures the call
  directly. That is why Amanu is not tied to a Zoom or
  Google Meet integration.
- **The two sides stay separate.** Amanu records the microphone and system
  audio independently, aligns them on one clock, and archives them as the left
  and right channels of one file. AssemblyAI receives the same separation as
  multichannel audio, so it does not have to guess which side a voice came
  from by loudness alone.
- **Recording must not change the meeting.** On macOS, Apple's duplex voice-processing
  route can attenuate or interrupt playback merely because recording started.
  Amanu therefore captures the microphone raw by default. After recording,
  LocalVQE removes acoustic echo from a microphone copy before recognition.
  A conservative text pass removes remaining exact phrase duplicates. None of
  this processing affects live playback or the saved source audio.
- **Capture is crash-recoverable.** The live tracks are uncompressed PCM in
  CAF containers on macOS and WAV containers on Windows, and are compressed
  only after the transcript exists. A hard
  kill can leave an unfinished AAC file unreadable; PCM preserves everything
  written before the interruption. On the next launch, Amanu adopts the
  interrupted session and puts it back into the normal processing queue.
- **The folder is the database.** `meta.json` and the artifacts beside it are
  the source of truth. There is no separate library to corrupt or migrate, and
  processing claims prevent the same recording from being processed twice.
  On macOS this also coordinates the app and CLI.
- **The macOS release is signed and notarized.** macOS grants microphone and
  system-audio access to the responsible app
  and its code signature. Amanu ships as a Developer ID-signed, hardened, and
  notarized bundle so those permissions survive updates. Windows releases
  carry an Authenticode code-signing certificate issued through Microsoft
  Artifact Signing, identifying the publisher as Fands Software LLC.
- **Updates wait for the recording.** Sparkle checks and installs signed
  macOS releases, but an update never quits Amanu in the middle of a meeting.
  Windows uses Velopack with a separate stable update feed. Updates wait
  until recording and processing are finished; portable copies do not update
  themselves.
- **Failures become tests.** The macOS automated suite covers interrupted
  sessions, silent or stalled tracks, route changes, sample-rate mismatches, concurrent
  processing, transcription fallbacks, and UI regressions. A separate window
  harness renders the main screens in English and Russian, in light and dark
  appearances.

The constraints behind these choices are documented in
[Things that will bite](docs/pitfalls.md). Design notes live in
[`docs/specs`](docs/specs/).

## Install

### macOS

Install with Homebrew:

```sh
brew install --cask gsamat/tap/amanu
```

Or download the disk image from the
[macOS release](https://github.com/gsamat/amanu/releases/download/v0.6.4/amanu-v0.6.4-macos-universal.dmg), drag
`Amanu.app` to Applications, and open it. The first-run setup requests
microphone, system-audio, and optional calendar access, then asks how meetings
should be transcribed and summarized.

### Windows

Download [Amanu-0.6.4-Setup.exe](https://github.com/gsamat/amanu/releases/download/windows-v0.6.4/Amanu-0.6.4-Setup.exe)
and run it. The installer includes the .NET and native transcription runtimes;
you do not need a separate .NET SDK or Python installation.

1. Open Amanu and allow desktop apps to access the microphone in Windows
   Settings → Privacy & security → Microphone.
2. In Settings, download a local transcription model or add an AssemblyAI,
   OpenAI, or ElevenLabs API key.
3. Choose Claude Code, Codex, an API key, or Ollama for summaries. For offline
   use, download the local models first and choose local backends for both
   transcription and summaries.
4. Enable the live transcript if wanted and download its separate model.
   Make a short recording and check both sides of the call in the transcript.

Closing the window leaves Amanu in the system tray; use Quit to stop it.
Start at sign-in can be changed in Settings. Installed copies check the stable
Windows update feed automatically.

For a copy without an installer, download
[Amanu-stable-Portable.zip](https://github.com/gsamat/amanu/releases/download/windows-v0.6.4/Amanu-stable-Portable.zip),
extract the entire archive, and open the top-level `Amanu.exe`. Portable copies
use the same settings and recordings folders and require manual updates.

#### Scoop

Save the [Amanu manifest](windows/packaging/scoop/amanu.json) as `amanu.json`.
With [Scoop](https://scoop.sh/) already installed, run this from the folder
containing that file:

```powershell
scoop install .\amanu.json
```

The manifest installs the portable release, verifies its SHA-256, and creates
an Amanu Start menu shortcut. It is pinned to Windows 0.6.4. To upgrade, quit
Amanu, run `scoop uninstall amanu`, then install the updated manifest. Recordings
and settings live outside Scoop's application directory and are retained.

#### WinGet

The package `FandsSoftware.Amanu` has been
[submitted to Microsoft's community repository](https://github.com/microsoft/winget-pkgs/pull/445053)
and has passed Microsoft's installation, metadata, and other validation checks.
It is awaiting review. Once merged and available in the source:

```powershell
winget install --id FandsSoftware.Amanu --exact --source winget
```

Until then, use Setup, the portable ZIP, or the Scoop manifest above. The
[WinGet manifests and maintenance instructions](windows/packaging/winget/README.md)
are included in this repository. Amanu has no published Chocolatey package yet.

## Requirements

### macOS

- macOS 14.2 or later.
- Apple Silicon for local transcription and the live transcript.
- The distributed app is universal (`arm64` and `x86_64`). On Intel, recording
  and cloud transcription paths are available, but the app has not yet been
  validated on physical Intel hardware. See [Old Macs](docs/old-macs.md) for
  the measured boundaries.

The release is signed with an Apple Developer ID certificate and carries a
stapled Apple notarization ticket.

### Windows

- Windows 11 24H2 or later on an x64 PC (build 26100 minimum; verified on 25H2). Windows 10, older Windows 11 builds,
  and native ARM64 packages have not been validated for this release.
- Microphone access for desktop apps.
- Internet access for cloud backends and the initial local model downloads.
  Final transcription models take about 270–890 MB each; the separate live
  model takes about 750 MB and uses additional memory for both audio tracks.
- Browser capture includes the call application's process tree, so other tabs
  in the same browser can be recorded too. Calendar integration is unavailable.

Public installers and the application are Authenticode-signed as **Fands
Software LLC** through [Microsoft Artifact Signing](https://learn.microsoft.com/en-us/azure/artifact-signing/overview).
Windows validates the publisher's signature; Microsoft is the certificate
service, while Fands Software LLC is the application's publisher.

## Build from source

### macOS

The macOS app is one Swift 6 package. SwiftPM builds the executable; `make app`
builds the pinned LocalVQE native assets, then assembles and signs the
application bundle without an Xcode project. Building from source requires
CMake as well as Xcode's command-line tools.

```sh
git clone https://github.com/gsamat/amanu.git
cd amanu
make app
make run-app
swift test
```

`make run-app` launches through LaunchServices, which matters because macOS
attributes privacy permissions to the process responsible for starting the
capture. A checkout with no signing certificate falls back to ad-hoc signing;
that is sufficient for development, although macOS may ask for permissions
again after a rebuild.

Before changing capture, packaging, permissions, or releases, read
[`CLAUDE.md`](CLAUDE.md), [Things that will bite](docs/pitfalls.md), and
[Releasing](docs/releasing.md).

### Windows

The Windows app uses C#/.NET 10 and WPF, with a separate core library and
Velopack packaging. Install the .NET 10 SDK, Git, CMake, and Visual Studio 2022
C++ Build Tools with the Desktop development with C++ workload and a Windows
11 SDK. Run PowerShell from a developer environment where CMake and MSVC are
available.

Windows source currently lives on a separate branch. To reproduce the public
release, check out its tag:

```powershell
git clone --branch windows-v0.6.4 https://github.com/gsamat/amanu.git amanu-windows
cd amanu-windows\windows
.\scripts\Build-Release.ps1 -Version 0.6.4
.\artifacts\publish\Amanu.exe
```

The script runs the core and Windows application tests, builds both pinned
native transcription runtimes, publishes a self-contained x64 app, and creates
Setup, a portable ZIP, and the stable update feed in `artifacts\release`.
Local builds are unsigned unless a signing certificate is supplied. The
public release workflow signs and verifies the payload and installer through
Microsoft Artifact Signing.

See [windows/README.md](windows/README.md) for individual build/test commands,
signing, and release packaging. Build, test, and recording checks must run on
Windows; a macOS build does not validate the Windows app.

## CLI

### macOS

First launch creates `~/.local/bin/amanu`, pointing into the installed app so
scripts use the same signed program as the UI.

```sh
amanu doctor                 # check permissions, engines, and configuration
amanu record start           # ask the running app to start recording
amanu record stop
amanu sessions               # list recordings and outstanding work
amanu process <folder>       # finish or retry one meeting
amanu format-transcripts     # rebuild AssemblyAI Markdown from saved transcripts
amanu setup                  # reopen first-run setup
```

Run `amanu --help` or `amanu <command> --help` for the complete command-line
interface. Most people never need it: recording and post-processing are
automatic, and the app exposes the same controls.

### Windows

Recording, import, retry, and configuration are available in the app and system
tray. A public Amanu command-line interface is not included in Windows.
The bundled `transcribe-cli.exe` and live worker processes are internal
transcription components. Claude Code and Codex CLIs are optional summary
backends, separate from an Amanu CLI.

## Configuration

Both platforms expose configuration through Settings, including an Advanced
tab. Most shared settings use the same names, but platform paths, credentials,
app identifiers, and hooks differ. Settings saves only overrides of defaults.

| | macOS | Windows |
| --- | --- | --- |
| Configuration | `~/.config/amanu/config.json` | `%LOCALAPPDATA%\Amanu Data\config.json` |
| Default recordings | `~/Recordings` | `%USERPROFILE%\Amanu Recordings` |
| API keys entered in Settings | `~/.config/amanu/keys/` | Windows Credential Manager (`Amanu/…`) |
| Call app identifiers | Bundle IDs, such as `us.zoom` | Executable names, such as `Zoom.exe` |

### macOS

Settings writes `~/.config/amanu/config.json`. The file is optional and stores
only values that differ from the defaults. A compact example:

```json
{
  "recordings_dir": "~/Recordings",
  "keep_audio": false,
  "analytics": true,
  "interface_language": "auto",
  "transcription": {
    "enabled": true,
    "engine": "auto",
    "cloud": "assemblyai",
    "language": "ru",
    "assemblyai": { "api_key_path": "~/.config/amanu/keys/assemblyai" }
  },
  "auto_record": {
    "enabled": true,
    "mic_activity": true,
    "calendar": false,
    "start_delay_seconds": 12,
    "stop_delay_seconds": 15,
    "min_duration_seconds": 45,
    "silence_stop_minutes": 10,
    "max_duration_minutes": 300,
    "apps": ["us.zoom", "com.google.Chrome"],
    "ignore_apps": []
  },
  "summary": {
    "enabled": true,
    "backend": "auto",
    "language": "ru"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` selects the session folder; `keep_audio` retains the compact
  stereo archive after a successful transcript; `on_stop` is a shell command
  run after processing; `analytics` controls anonymous product-usage reporting.
- `on_stop` gets the session folder as its only argument and runs once per
  transcript, after naming and summarizing have had their pass — done,
  turned off, failed, or deferred for want of a model (a summary that arrives
  later does not run it again). It never runs while an amanu is still
  finishing the session, and a crash in between is made good by the next
  launch. With transcription off it runs once the recording is archived; a
  recording that could not be transcribed does not run it.
- `transcription.*` covers `enabled`, `engine`, `cloud`, `local_engine`, `model`, and `language`.
  `local_engine` is `parakeet` by default, `whisper`, or `gigaam`; Whisper
  downloads about 550 MB once. GigaAM v3 downloads about 260 MB and runs
  locally through Handy's `transcribe.cpp` Metal/CPU runtime. It is Russian-only;
  Amanu splits long recordings into 20-second pieces to stay inside its trained
  utterance window.
  Provider overrides are `transcription.openai.model`,
  `transcription.openai.api_key_path`,
  `transcription.assemblyai.api_key`,
  `transcription.assemblyai.api_key_path`, and
  `transcription.assemblyai.speech_model`, plus
  `transcription.elevenlabs.api_key` and
  `transcription.elevenlabs.api_key_path`. Choose `elevenlabs` as
  `transcription.cloud` or `transcription.engine` to use Scribe v2. It sends
  the microphone and system channels separately, with speaker diarization on
  each; a mono import uses the same diarization. Set `ELEVENLABS_API_KEY` or
  save a key in `~/.config/amanu/keys/elevenlabs`. `live_transcription.enabled`
  controls the on-device preview.
- `auto_record.*` covers `enabled`, `mic_activity`, `calendar`,
  `start_delay_seconds`, `stop_delay_seconds`, `min_duration_seconds`,
  `max_duration_minutes`, `silence_stop_minutes`, `apps`, and `ignore_apps`.
  On macOS, `apps` accepts app names (such as `Comet` or `Comet Helper`) as
  well as bundle-id prefixes; browser helpers resolve to the whole browser
  for audio capture. `auto_record.any_app` (off by default) records microphone
  activity from apps outside this list too. Dictation tools and `ignore_apps`
  still stay excluded. Turn it on in Advanced settings; turning it off restores
  the configured call list. An explicit `apps: []` in the config also accepts
  any app, while clearing the list field in Settings restores the standard list.
- `speaker_names.*` covers `enabled`, `backend`, and `model`. Naming sends
  the transcript wherever `summary.backend` does, and to no model when
  summaries are off, unless `speaker_names.backend` names a backend of its own.
- `summary.*` covers `enabled`, `backend`, `language`, `model`,
  `openai_model`, `openai_base_url`, `ollama_model`, `ollama_base_url`,
  `template`, `api_key_path`, `openai_api_key_path`, and
  `openai_compatible_api_key_path`. The two Base URLs
  allow OpenAI-compatible servers and a non-default Ollama host; only a
  loopback Ollama URL keeps the transcript on your computer, and any other host
  must be reached over https — plain http is refused for remote servers. The OpenAI
  key is only ever sent to OpenAI: `summary.openai_api_key_path` names it for
  summaries while `openai_base_url` is OpenAI's own, and
  `transcription.openai.api_key_path` names it for transcription (an older
  config's `summary.openai_api_key_path` still counts for transcription while
  the summary talks to OpenAI). The key for any other server is
  `summary.openai_compatible_api_key_path`, or one pasted in Setup, which is
  kept in `~/.config/amanu/keys/openai-compatible`. `amanu doctor` walks the configured summary backend,
  including whether Ollama is answering and has the chosen model. `template` contains
  the complete summary instructions and starts with Amanu's built-in default.
  In Settings → Setup → My own key, choose OpenAI, Anthropic, or
  OpenAI-compatible. The compatible option exposes the server URL and uses its
  own key. `summary.openai_compatible: false` selects OpenAI’s API while keeping
  a saved custom URL; `true` selects that URL. Older configs infer the choice
  from `openai_base_url` when the setting is absent.
- `mic_voice_processing` enables Apple's capture-time voice processing;
  `offline_echo_cancellation` (on by default) instead cleans a copy of the mic
  after recording, using system audio as the playback reference. It never
  opens a playback device or changes the archived source audio. Transcription
  uses a separate cache for cleaned audio; the first re-transcription of an
  older recording therefore needs a new provider request. Reference silence
  before playback and after a one-second acoustic-tail holdoff keeps the
  original microphone samples exactly. If playback occurs later, the model
  still consumes leading silence from the start so its delay-estimation clock
  remains aligned with the recording; an entirely silent reference is detected
  first and skips the model;
  `transcript_echo_filter` removes proven duplicate far-end speech later;
  `system_audio` is `app` or `all`; `calendar` controls meeting context; and
  `user_name` replaces “me” in named transcripts.
- `interface_language` is `auto`, `en`, or `ru`. `dock_icon`, `menu_bar_icon`,
  and `window` control where Amanu appears.

Inline and file-based API keys remain supported for compatibility, but the UI
never displays an inline secret. Environment variables take precedence.

### Windows

Settings writes `%LOCALAPPDATA%\Amanu Data\config.json`. The recordings folder
is under your user profile by default, outside Documents to avoid OneDrive's
automatic Documents backup. Existing beta data is migrated on upgrade.
API keys are entered in Settings and kept in Windows Credential Manager;
the macOS key-file paths and environment-variable instructions above do not
apply to Windows.

A compact Windows example for local processing:

```json
{
  "keep_audio": true,
  "analytics": false,
  "interface_language": "auto",
  "transcription": {
    "engine": "parakeet",
    "local_engine": "parakeet"
  },
  "summary": {
    "backend": "ollama",
    "ollama_base_url": "http://127.0.0.1:11434",
    "ollama_model": "qwen3:8b"
  },
  "speaker_names": { "backend": "summary" }
}
```

Download Parakeet in Settings and make the selected Ollama model available
before using this example offline.

- `transcription.*` supports `enabled`, `engine`, `cloud`, `local_engine`,
  `language`, `openai.model`, and `assemblyai.speech_model`. Choose `parakeet`,
  `whisper`, or `gigaam` for local processing, or `assemblyai`, `openai`, or
  `elevenlabs` for a specific cloud engine. `auto` uses the configured cloud
  engine when available and otherwise the selected local engine.
- `summary.*` supports `enabled`, `backend`, `language`, `model`,
  `openai_model`, `openai_base_url`, `ollama_model`, `ollama_base_url`, and
  `template`. Backend names are `auto`, `claude-cli`, `anthropic-api`,
  `codex-cli`, `openai-api`, `ollama`, and `none`. `auto` tries them in that
  order, ending with Ollama. With the default `openai_model`, Codex uses its
  own configured model; a different Windows `summary.openai_model` also
  overrides the Codex CLI model. On macOS 0.6.1, this setting applies only
  to the OpenAI API.
- `speaker_names.*` supports `enabled`, `backend`, and `model`. The default
  backend `summary` follows the summary route and asks no model when summaries
  are disabled. An explicit backend chooses a separate naming route.
- `auto_record.*` uses executable names in `apps` and `ignore_apps`; the default
  start delay is 3 seconds on Windows and 12 seconds on macOS. Other controls
  cover `enabled`, `mic_activity`, `stop_delay_seconds`, `min_duration_seconds`,
  `silence_stop_minutes`, and `max_duration_minutes`. Windows has no calendar
  trigger.
- `live_transcription.enabled` controls the separate local streaming model.
  `system_audio` is `app` or `all`; `transcript_echo_filter` removes duplicate
  far-end speech. Apple's `mic_voice_processing` and LocalVQE's
  `offline_echo_cancellation` are macOS-only settings.
- `start_at_login`, `tray_icon`, and `taskbar_icon` control Windows startup and
  appearance. `recordings_dir`, `keep_audio`, `analytics`, `interface_language`,
  and `user_name` have the same purposes as on macOS.
- `on_stop` is an object with `executable` and `arguments`, rather than a shell
  command. `{session}` in an argument expands to the meeting folder. For
  example, `{"executable":"notepad.exe","arguments":["{session}\\summary.md"]}`
  opens the summary after processing. It runs once per session and does not
  wait for the launched application to close.

## Project

Amanu began as a fork of [digimata/quill](https://github.com/digimata/quill)
and has since been substantially rewritten. The fork grew into a native app
with first-run setup, automatic recording, live transcription, speaker naming,
a resumable processing pipeline, local and cloud backends, crash recovery, a
regression suite, and signed automatic updates. The Windows edition is a
separate native C#/.NET and WPF implementation using WASAPI capture. It shares
the meeting-folder format, local/cloud model choices, and summary conventions
with macOS, while each platform keeps its own capture, permissions, packaging,
and update mechanism. Windows build and test instructions are in
[windows/README.md](windows/README.md). [FORK.md](FORK.md) records the
project's provenance and explains how the architecture diverged.

The name comes from *amanuensis*: a person whose job is to write down what is
said. Amanu is free software under the [MIT license](LICENSE); dependency
licenses are listed in [third-party notices](THIRD-PARTY-NOTICES.md).
