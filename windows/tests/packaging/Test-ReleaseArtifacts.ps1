$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$directory = Join-Path ([IO.Path]::GetTempPath()) ("amanu-packaging-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
try {
    $names = @('Amanu-stable-Setup.exe', 'Amanu-stable-Portable.zip', "Amanu-$version-stable-full.nupkg")
    foreach ($name in $names) { [IO.File]::WriteAllText((Join-Path $directory $name), "test payload $name") }
    $inventory = @(
        @{ RelativeFileName = $names[0]; Type = 'Installer' },
        @{ RelativeFileName = $names[1]; Type = 'Portable' },
        @{ RelativeFileName = $names[2]; Type = 'Full' }
    )
    $inventoryPath = Join-Path $directory 'assets.stable.json'
    [IO.File]::WriteAllText($inventoryPath, (ConvertTo-Json -InputObject $inventory -Compress))
    & (Join-Path $root 'windows/scripts/Finalize-ReleaseArtifacts.ps1') -ReleaseDirectory $directory
    if (Test-Path -LiteralPath (Join-Path $directory $names[0])) { throw 'Unversioned installer remains.' }
    $entries = @(Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json)
    if (($entries | Where-Object { $_.Type -eq 'Installer' }).RelativeFileName -ne "Amanu-$version-Setup.exe") {
        throw 'Installer inventory does not reference the versioned filename.'
    }
    foreach ($entry in $entries) {
        if (-not (Test-Path -LiteralPath (Join-Path $directory $entry.RelativeFileName))) { throw 'Inventory points at a missing file.' }
    }
    $lines = @(Get-Content -LiteralPath (Join-Path $directory 'SHA256SUMS'))
    if ($lines.Count -ne 4) { throw 'Expected checksums for three assets and their inventory.' }
    foreach ($line in $lines) {
        $parts = $line -split '  ', 2
        $actual = (Get-FileHash -LiteralPath (Join-Path $directory $parts[1]) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $parts[0]) { throw "Checksum mismatch: $($parts[1])" }
    }
    Write-Host 'PASS: versioned installer, valid Velopack inventory, and checksums'
} finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
