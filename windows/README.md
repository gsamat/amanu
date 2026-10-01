# Amanu for Windows

The Windows implementation requires Windows 11 24H2 (build 26100) or later on x64.
The app's evaluated `SupportedOSPlatformVersion` is `10.0.26100.0`.
Local installation, audio and UI checks have run on Windows 11 25H2 (build 26200);
24H2 is the declared minimum and has not yet been verified on a 24H2 desktop.
Windows 10 is not supported. Its compatibility research is separate from this release.
Its approved architecture and beta gates are documented in
[`docs/specs/2026-09-20-windows-app-design.md`](../docs/specs/2026-09-20-windows-app-design.md).

The solution is split into a cross-platform core, a native WPF desktop shell,
Windows audio/lifecycle adapters, and tests. Release packaging uses Velopack.
GitHub Actions signs Windows releases with Azure Artifact Signing as Fands Software LLC.

## Build

On Windows with the .NET 10 SDK:

```powershell
.\scripts\Build-Release.ps1 -Version 0.6.0
```

The script runs the core and Windows live tests, builds the final transcription
CLI and streaming runtime from pinned source commits, publishes a self-contained x64 app, and writes the installer
plus stable update feed to `artifacts\release`. The build requires Git, CMake,
and Visual Studio C++ Build Tools. Pass
`-CertificatePath` and `-CertificatePassword` only for a controlled signing
certificate.

The GitHub Actions workflow uses Azure Artifact Signing via OIDC and the
`windows-signing` GitHub Environment. Its configuration uses `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`,
`AZURE_ARTIFACT_SIGNING_ENDPOINT`, `AZURE_ARTIFACT_SIGNING_ACCOUNT`, and
`AZURE_ARTIFACT_SIGNING_PROFILE`. Downloadable Actions artifacts require Azure
signing; the workflow verifies the publisher and timestamp before uploading,
including files extracted from the update package and portable ZIP. Velopack
also signs its generated launcher and updater during packaging. First-party
DLLs are signed before packaging; third-party DLLs are left untouched.
Local builds can still be unsigned. A PFX fallback remains available through
`WINDOWS_BETA_CERTIFICATE_BASE64` and `WINDOWS_BETA_CERTIFICATE_PASSWORD`.

Azure login is tenant-only (`allow-no-subscriptions: true`): the signing app
needs the Certificate Profile Signer role on the profile, not access to manage
the Azure subscription.

## Signed test builds without a release

Create a short-lived branch from the Windows development
branch (or from `master` once Windows is merged). Run **Windows release** in GitHub
Actions, choose the branch and package version, and leave `publish_release`
disabled. `upload_artifact` is enabled by default, while `publish_release` is
disabled. Disable artifact upload explicitly for a build-only smoke test.

```sh
gh workflow run windows-beta.yml -R gsamat/amanu --ref windows/my-change \
  -f version=0.6.0 -f upload_artifact=true -f publish_release=false
```

After the run succeeds, download `Amanu-Windows-<version>-x64` from its Artifacts
section, extract it, and install `Amanu-stable-Setup.exe`. The artifact is public
to signed-in GitHub readers and expires after 30 days. This creates no GitHub
Release and does not publish an automatic update; testers install the new
build manually. The installer and Amanu payload have production-trusted
signatures identifying **Fands Software LLC**.

Azure trusts the `windows-signing` environment rather than a particular branch.
The environment allows any branch in this repository, so new testing branches
need no Azure or GitHub policy changes. Forks do not match the Azure trust,
which is bound to immutable repository IDs:

```text
repo:gsamat@705006/amanu@1338189078:environment:windows-signing
```

Enabling `publish_release` separately creates a stable GitHub release containing
the Velopack feed, which makes the installed app's automatic updater operational.

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for release changes and [BETA.md](BETA.md) for the hardware tester checklist.
