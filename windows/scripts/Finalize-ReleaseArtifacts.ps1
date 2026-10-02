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
$inventoryPath = Join-Path $ReleaseDirectory 'assets.stable.json'
$inventory = @(Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json)
$installerEntries = @($inventory | Where-Object { $_.Type -eq 'Installer' })
if ($installerEntries.Count -ne 1) { throw 'Expected one installer in Velopack asset inventory.' }
$installerEntries[0].RelativeFileName = [IO.Path]::GetFileName($versionedInstaller)
foreach ($asset in $inventory) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDirectory $asset.RelativeFileName))) {
        throw "Missing Velopack asset: $($asset.RelativeFileName)"
    }
}
[IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $inventory -Compress), [Text.UTF8Encoding]::new($false))
$checksums = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File |
    Where-Object { $_.Name -ne 'SHA256SUMS' } | Sort-Object Name | ForEach-Object {
        "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
    })
[IO.File]::WriteAllLines((Join-Path $ReleaseDirectory 'SHA256SUMS'), $checksums, [Text.Encoding]::ASCII)
Write-Host "Versioned installer: $versionedInstaller"
