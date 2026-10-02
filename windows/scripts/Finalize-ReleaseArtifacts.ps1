param(
    [Parameter(Mandatory = $true)] [string] $ReleaseDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid VERSION: $version" }
$installer = Join-Path $ReleaseDirectory 'Amanu-stable-Setup.exe'
$versionedInstaller = Join-Path $ReleaseDirectory "Amanu-$version-Setup.exe"
if (Test-Path -LiteralPath $versionedInstaller) { throw "Installer already exists: $versionedInstaller" }
Move-Item -LiteralPath $installer -Destination $versionedInstaller
$checksums = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File |
    Where-Object { $_.Name -ne 'SHA256SUMS' } | Sort-Object Name | ForEach-Object {
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
    })
[IO.File]::WriteAllLines((Join-Path $ReleaseDirectory 'SHA256SUMS'), $checksums, [Text.Encoding]::ASCII)
Write-Host "Versioned installer: $versionedInstaller"
