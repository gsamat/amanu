param(
    [Parameter(Mandatory = $true)] [string] $ReleaseDirectory,
    [Parameter(Mandatory = $true)] [string] $Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid release version: $Version" }

$metadataPath = Join-Path $ReleaseDirectory 'assets.stable.json'
$assets = @(Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json)
$installers = @($assets | Where-Object Type -eq 'Installer')
if ($installers.Count -ne 1) { throw 'Expected exactly one installer in assets.stable.json.' }

$installerName = "Amanu-$Version-Setup.exe"
$sourceName = $installers[0].RelativeFileName
if ($sourceName -notin @('Amanu-stable-Setup.exe', $installerName)) {
    throw "Unexpected installer filename in assets.stable.json: $sourceName"
}
$sourcePath = Join-Path $ReleaseDirectory $sourceName
$installerPath = Join-Path $ReleaseDirectory $installerName
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Installer is missing: $sourcePath" }
if ($sourceName -ne $installerName) {
    if (Test-Path -LiteralPath $installerPath) { throw "Versioned installer already exists: $installerPath" }
    # Only the filename changes; retain the exact Authenticode-signed bytes.
    Rename-Item -LiteralPath $sourcePath -NewName $installerName
}

$installers[0].RelativeFileName = $installerName
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($metadataPath, ($assets | ConvertTo-Json -Depth 10 -AsArray), $utf8)

# Generate checksums after final filenames and metadata have been written.
$checksums = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File |
    Where-Object Name -ne 'SHA256SUMS' | Sort-Object Name | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $($_.Name)"
    })
[IO.File]::WriteAllLines((Join-Path $ReleaseDirectory 'SHA256SUMS'), [string[]] $checksums, $utf8)

Write-Output $installerPath
