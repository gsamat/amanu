# Amanu for Windows

The public Windows release is **0.6.3**, for Windows 11 24H2 or later on x64. It uses a native
C#/.NET 10 and WPF application, a separate core library, WASAPI capture, and
Velopack packaging. The installer and application are signed as **Fands
Software LLC** through Microsoft Artifact Signing.

[Installer](https://github.com/gsamat/amanu/releases/download/windows-v0.6.3/Amanu-stable-Setup.exe) ·
[Portable ZIP](https://github.com/gsamat/amanu/releases/download/windows-v0.6.3/Amanu-stable-Portable.zip) ·
[Release notes](https://github.com/gsamat/amanu/releases/tag/windows-v0.6.3)

The [main README](../README.md) covers installation, requirements, and
configuration. The [hardware checklist](https://github.com/gsamat/amanu/blob/windows-v0.6.3/windows/BETA.md) covers manual testing.
The original [design](https://github.com/gsamat/amanu/blob/windows-v0.6.3/docs/specs/2026-09-20-windows-app-design.md) records the
architecture decisions; its beta distribution gates describe the original
plan, rather than the current signed release.

## Get the source

Windows currently has a separate development branch. The repository's default
branch does not yet contain the released Windows implementation. To reproduce
0.6.3, use the release tag:

```powershell
git clone --branch windows-v0.6.3 https://github.com/gsamat/amanu.git amanu-windows
cd amanu-windows\windows
```

The commands below run from that `windows` directory. They describe the public
release source, which is newer than the earlier beta tree in some checkouts.

## Build and test

Install Git, the .NET 10 SDK, CMake, and Visual Studio 2022 C++ Build Tools with
Desktop development with C++ and a Windows 11 SDK. Use a developer PowerShell
with CMake and the MSVC toolchain available.

For managed-code development:

```powershell
dotnet restore Amanu.Windows.slnx
dotnet build Amanu.Windows.slnx -c Release --no-restore
dotnet test tests\Amanu.Core.Tests\Amanu.Core.Tests.csproj -c Release --no-restore
dotnet test tests\Amanu.Live.Tests\Amanu.Live.Tests.csproj -c Release --no-restore
dotnet run --project src\Amanu.App\Amanu.App.csproj -c Release
```

A managed build alone does not bundle the native transcription runtimes. To
exercise local and live recognition and create a complete package, run:

```powershell
.\scripts\Build-Release.ps1 -Version 0.6.3
.\artifacts\publish\Amanu.exe
```

The release script restores packages, runs both test projects, publishes a
self-contained x64 app, builds the pinned final-transcript CLI and streaming
runtime, and packages the installer, portable ZIP, and stable update feed in
`artifacts\release`. Users of the finished package need no .NET SDK, CMake,
Python, or separate native runtime installation. Models download from Settings.

Both native builds use portable CPU variants rather than the build computer's
CPU features. The final-transcript build runs a CPU discovery/startup check.
Live recognition uses a separate local Nemotron streaming model; see
[Windows live transcription](https://github.com/gsamat/amanu/blob/windows-v0.6.3/windows/LIVE_TRANSCRIPTION.md)
for the real-time audio harness and CPU/memory behavior.

Builds, tests, and audio/device checks must run on Windows. Cross-compiling on
macOS or a green CI build does not replace testing the actual Windows recording
flow. The release notes record the checks performed for each shipped version.

## Signing and release packaging

Local builds are unsigned by default. `Build-Release.ps1` accepts
`-CertificatePath` and `-CertificatePassword` for local certificate signing.
Do not put signing credentials in the repository or public logs.

The **Windows release** GitHub Actions workflow (`windows-beta.yml`, retaining
its historical filename) signs through Azure Artifact Signing with OIDC and
the `windows-signing` GitHub Environment. Its configuration uses
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_ARTIFACT_SIGNING_ENDPOINT`,
`AZURE_ARTIFACT_SIGNING_ACCOUNT`, and `AZURE_ARTIFACT_SIGNING_PROFILE`.
The Azure login is tenant-only (`allow-no-subscriptions: true`); the signing
identity needs the Certificate Profile Signer role on the profile.

The workflow signs first-party payloads and the generated launcher/updater,
then verifies signatures, publisher, and timestamp for Setup and files
extracted from the update package and portable ZIP. Third-party DLLs retain
their original signatures. Downloadable workflow artifacts require Azure
signing. An optional PFX configuration remains available through
`WINDOWS_BETA_CERTIFICATE_BASE64` and `WINDOWS_BETA_CERTIFICATE_PASSWORD`.
See the [released workflow](https://github.com/gsamat/amanu/blob/windows-v0.6.3/.github/workflows/windows-beta.yml)
for the exact gates.

For a signed test build, select the Windows branch and package version in
Actions. Keep `publish_release` disabled and `upload_artifact` enabled. This
produces a downloadable signed artifact without publishing an automatic update.
Enabling `publish_release` creates a Windows GitHub release with the complete
stable Velopack feed. Windows tags use `windows-v<version>`; macOS uses the same version number;
its Sparkle feed remains separate.

## Command-line components

Windows has no public Amanu CLI. Recording, import, retry, retranscription,
speaker renaming, and Settings are available in the app and system tray.
`transcribe-cli.exe` and the streaming worker are internal components bundled
with Amanu.

Claude Code and Codex are optional summary backends. Settings detects supported
standalone and desktop-bundled installations, including Claude Desktop from
the Microsoft Store. Use Settings to install or sign in to the selected CLI;
its subscription login can be separate from the desktop chat app's login.
These backends receive transcripts for cloud processing.

## Scoop package

The repository includes a [Scoop manifest](packaging/scoop/amanu.json) for the
public portable ZIP. Save it as `amanu.json` and, with Scoop already installed,
run from the folder containing that file:

```powershell
scoop install .\amanu.json
```

This installs Windows 0.6.3 with a pinned SHA-256 and Start menu shortcut.
It has no built-in updater. When preparing a newer manifest, update both the
version-specific URL and SHA-256 from the new release's `SHA256SUMS`; validate
the archive layout and the launcher's signature on Windows. To upgrade, quit Amanu, run
`scoop uninstall amanu`, then install the updated manifest. Its recordings, models, credentials, and settings are outside the
Scoop package directory.

The Scoop manifest has not been submitted to Scoop Extras.

## WinGet package

`FandsSoftware.Amanu` 0.6.1 is submitted in
[Microsoft's package repository PR](https://github.com/microsoft/winget-pkgs/pull/445053).
Microsoft's validation checks have passed; it is awaiting review. A public
`winget install` command is not available yet. The
[manifest set and maintenance instructions](packaging/winget/README.md)
are kept here for subsequent Windows releases. Amanu has no published
Chocolatey package yet.
