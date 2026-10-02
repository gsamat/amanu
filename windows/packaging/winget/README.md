# Amanu in WinGet

The package identifier is `FandsSoftware.Amanu`. The initial submission is
[PR #445053](https://github.com/microsoft/winget-pkgs/pull/445053). Microsoft's
installation, metadata, and other validation checks have passed; review is pending.
Version 0.6.4 is submitted in [draft PR #445780](https://github.com/microsoft/winget-pkgs/pull/445780).
Its manifests passed local Windows validation. Isolated install, upgrade, and uninstall
tests could not run because no isolated Windows environment was available; the PR
remains a draft pending Microsoft validation results.
Version 0.6.5 is submitted in [PR #445793](https://github.com/microsoft/winget-pkgs/pull/445793).
Its manifests passed local Windows validation and pin the downloaded, signature-verified
versioned installer and SHA-256. Clean installation, native upgrade from 0.6.4, and
uninstall passed in a temporary standard Windows account with a separate profile and
HKCU. Versions, signatures, uninstall registration, application-file removal, and
retention of synthetic user data were verified; the account and profile were removed.
These tests used Setup.exe and Update.exe directly, rather than local-manifest WinGet
installation. All Microsoft validation checks, including installation and metadata,
passed. The PR is ready for review; the package is not yet available in the public catalog.

Each Windows release has a
three-file manifest set: version, installer, and default locale. The submitted
0.6.1 manifests use the repository's currently recommended schema, 1.12.0.

The installer is the public, signed Velopack Setup from the version-specific
GitHub release. Installation is per user. Silent installation does not launch
Amanu, and no separate .NET or native runtime installation is required.

The signature identifies Fands Software LLC, while the package's current
Apps & Features registration uses Publisher `Amanu` and registry key `Amanu`.
`AppsAndFeaturesEntries` and `ProductCode` preserve this mapping so WinGet can
recognize installations and upgrades.

## Verify a candidate on Windows

Run from this directory:

```powershell
winget validate --manifest .\0.6.1
```

Use Windows Sandbox or a temporary Windows test account for installation tests.
The test account must have a separate profile and HKCU; a custom installation
folder under the working user alone does not isolate the uninstall registration.
Do not overwrite a working Amanu installation to test a manifest.

In that isolated environment, enable local manifests with an administrator
process for the same Windows user if needed, then run:

```powershell
winget settings --enable LocalManifestFiles
winget install --manifest .\0.6.1 --silent --accept-package-agreements
winget list --name Amanu
winget uninstall --name Amanu --exact --silent
```

Also install the preceding release and check an upgrade with:

```powershell
winget upgrade --manifest .\0.6.1 --silent --accept-package-agreements
```

Check the installed file version, Authenticode signature, HKCU uninstall entry,
exit codes, and removal of the application files. Confirm that recording data
and settings are retained. WinGet stores administrative settings per user;
enabling `LocalManifestFiles` under a different administrator account does not
enable it for a standard test account. Use an isolated environment where the
test user can elevate, such as Windows Sandbox, for the complete manifest test.
Restore the original local-manifest setting and
remove the temporary account/profile or close Sandbox after testing.

## Submit and maintain

Copy only the three YAML files for one version to
`manifests/f/FandsSoftware/Amanu/<version>/` in a fork of
[`microsoft/winget-pkgs`](https://github.com/microsoft/winget-pkgs), and submit a
PR titled `New package: FandsSoftware.Amanu version <version>` (or `Update:` for
subsequent releases). Follow the current contribution checklist and PR template.

For every new Windows release, update all three `PackageVersion` values,
installer URL, SHA-256, and release-notes URL. Confirm current installer switches,
minimum OS, and Apps & Features metadata, then repeat the Windows checks. Do
not replace an old version's URL with a moving latest-download redirect.
The WinGet package becomes publicly installable only after Microsoft's checks
and merge; a prepared or submitted manifest is not a published package.
