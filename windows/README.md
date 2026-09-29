# Amanu for Windows

The Windows implementation targets Windows 11 25H2 on x64. Its approved
architecture and beta gates are documented in
[`docs/specs/2026-09-20-windows-app-design.md`](../docs/specs/2026-09-20-windows-app-design.md).

The solution is split into a cross-platform core, a native WPF desktop shell,
Windows audio/lifecycle adapters, and tests. Release packaging uses Velopack.
GitHub Actions signs Windows betas with Azure Artifact Signing as Fands Software LLC.

## Build

On Windows with the .NET 10 SDK:

```powershell
.\scripts\Build-Beta.ps1 -Version 0.6.0-beta.4
```

The script runs the tests, builds the local transcribe.cpp CLI from a pinned
source commit, publishes a self-contained x64 app, and writes the installer
plus beta update feed to `artifacts\release`. The build requires Git, CMake,
and Visual Studio C++ Build Tools. Pass
`-CertificatePath` and `-CertificatePassword` only for a controlled beta
certificate.

The GitHub Actions workflow uses Azure Artifact Signing via OIDC and the
`windows-signing` GitHub Environment. Its configuration uses `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`,
`AZURE_ARTIFACT_SIGNING_ENDPOINT`, `AZURE_ARTIFACT_SIGNING_ACCOUNT`, and
`AZURE_ARTIFACT_SIGNING_PROFILE`. Downloadable Actions artifacts require Azure
signing; the workflow verifies the publisher and timestamp before uploading.
Local builds can still be unsigned. A PFX fallback remains available through
`WINDOWS_BETA_CERTIFICATE_BASE64` and `WINDOWS_BETA_CERTIFICATE_PASSWORD`.

Azure login is tenant-only (`allow-no-subscriptions: true`): the signing app
needs the Certificate Profile Signer role on the profile, not access to manage
the Azure subscription.

## Signed test builds without a release

Create a short-lived branch from the Windows development
branch (or from `master` once Windows is merged). Run **Windows beta** in GitHub
Actions, choose the branch and a new beta version, enable `upload_artifact`, and
leave `publish_release` disabled. Both options are disabled by default.

```sh
gh workflow run windows-beta.yml -R gsamat/amanu --ref windows/my-change \
  -f version=0.6.0-beta.5 -f upload_artifact=true -f publish_release=false
```

After the run succeeds, download `Amanu-Windows-<version>-x64` from its Artifacts
section, extract it, and install `Amanu-beta-Setup.exe`. The artifact is public
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

Enabling `publish_release` separately creates a GitHub prerelease containing
the Velopack feed, which makes the installed beta's automatic updater operational.

See [BETA.md](BETA.md) for the current feature boundary and tester checklist.
