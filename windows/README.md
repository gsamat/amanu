# Amanu for Windows

The Windows implementation targets Windows 11 25H2 on x64. Its approved
architecture and beta gates are documented in
[`docs/specs/2026-09-20-windows-app-design.md`](../docs/specs/2026-09-20-windows-app-design.md).

The solution is split into a cross-platform core, a native WPF desktop shell,
Windows audio/lifecycle adapters, and tests. Release packaging uses Velopack;
public signing will use Azure Artifact Signing after the legal publisher is
selected.

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

The GitHub Actions workflow is already wired for Azure Artifact Signing via
OIDC. Once the publisher is selected, configure `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`AZURE_ARTIFACT_SIGNING_ENDPOINT`, `AZURE_ARTIFACT_SIGNING_ACCOUNT`, and
`AZURE_ARTIFACT_SIGNING_PROFILE`. Until then it can create an unsigned internal
beta. A PFX fallback remains available through
`WINDOWS_BETA_CERTIFICATE_BASE64` and `WINDOWS_BETA_CERTIFICATE_PASSWORD`.

The manual GitHub Actions run uploads an artifact by default. Enabling its
`publish_release` input creates a GitHub prerelease containing the Velopack
feed, which makes the installed beta's automatic updater operational.

See [BETA.md](BETA.md) for the current feature boundary and tester checklist.
