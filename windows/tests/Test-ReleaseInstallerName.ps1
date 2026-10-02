param(
    [string] $ScriptPath = (Join-Path $PSScriptRoot '../scripts/Set-ReleaseInstallerName.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function New-ReleaseFixture {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "amanu release name $([Guid]::NewGuid())"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $directory 'Amanu-stable-Setup.exe'), [byte[]](0, 1, 2, 255))
    [IO.File]::WriteAllText((Join-Path $directory 'Amanu-0.6.4-stable-full.nupkg'), 'update package')
    [IO.File]::WriteAllText((Join-Path $directory 'releases.stable.json'), '{"Assets":[]}')
    $assets = @(
        @{ RelativeFileName = 'Amanu-stable-Setup.exe'; Type = 'Installer' },
        @{ RelativeFileName = 'Amanu-0.6.4-stable-full.nupkg'; Type = 'Full' }
    )
    [IO.File]::WriteAllText((Join-Path $directory 'assets.stable.json'), ($assets | ConvertTo-Json))
    return $directory
}

function Assert-Rejected([scriptblock] $Action, [string] $ExpectedMessage) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like "*$ExpectedMessage*") "Expected rejection '$ExpectedMessage', got '$message'."
}

$tests = @(
    @{
        Name = 'Installer name, metadata and checksums agree without changing signed bytes or the update feed'
        Run = {
            param($directory)
            $result = & $ScriptPath -ReleaseDirectory $directory -Version '0.6.4'
            $expectedPath = Join-Path $directory 'Amanu-0.6.4-Setup.exe'
            Assert-True ($result -eq $expectedPath) 'The returned installer path must include the package version.'
            Assert-True (Test-Path -LiteralPath $expectedPath) 'The versioned installer was not created.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $directory 'Amanu-stable-Setup.exe'))) 'The unversioned installer remains.'
            Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($expectedPath)) -eq 'AAEC/w==') 'Installer bytes changed; an Authenticode signature would be invalidated.'
            $assets = @(Get-Content -LiteralPath (Join-Path $directory 'assets.stable.json') -Raw | ConvertFrom-Json)
            Assert-True (@($assets | Where-Object Type -eq 'Installer')[0].RelativeFileName -eq 'Amanu-0.6.4-Setup.exe') 'Installer metadata still points at a stale filename.'
            Assert-True (@($assets | Where-Object Type -eq 'Full')[0].RelativeFileName -eq 'Amanu-0.6.4-stable-full.nupkg') 'Update package metadata changed.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'releases.stable.json')) -eq '{"Assets":[]}') 'The updater feed changed.'
            $lines = @(Get-Content -LiteralPath (Join-Path $directory 'SHA256SUMS'))
            Assert-True ($lines.Count -eq 4) 'Every final release file must have exactly one checksum.'
            foreach ($line in $lines) {
                Assert-True ($line -match '^([a-f0-9]{64})  (.+)$') "Malformed checksum: $line"
                $expectedHash = $Matches[1]
                $name = $Matches[2]
                Assert-True ($name -ne 'SHA256SUMS') 'The checksum file must not include itself.'
                $actualHash = (Get-FileHash -LiteralPath (Join-Path $directory $name) -Algorithm SHA256).Hash.ToLowerInvariant()
                Assert-True ($actualHash -eq $expectedHash) "Wrong checksum for $name"
            }
            Assert-True (@($lines | Where-Object { $_ -like '*  Amanu-0.6.4-Setup.exe' }).Count -eq 1) 'Installer checksum does not use the public filename.'
        }
    },
    @{
        Name = 'An existing versioned installer is never overwritten'
        Run = {
            param($directory)
            $path = Join-Path $directory 'Amanu-0.6.4-Setup.exe'
            [IO.File]::WriteAllText($path, 'existing installer')
            $metadata = [IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json'))
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.6.4' } 'already exists'
            Assert-True ([IO.File]::ReadAllText($path) -eq 'existing installer') 'Existing installer was overwritten.'
            Assert-True (Test-Path -LiteralPath (Join-Path $directory 'Amanu-stable-Setup.exe')) 'Original installer was lost.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json')) -eq $metadata) 'Metadata changed after a rejected rename.'
        }
    },
    @{
        Name = 'Missing installer leaves metadata unchanged'
        Run = {
            param($directory)
            Remove-Item -LiteralPath (Join-Path $directory 'Amanu-stable-Setup.exe')
            $metadata = [IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json'))
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '0.6.4' } 'missing'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'assets.stable.json')) -eq $metadata) 'Metadata changed without an installer.'
        }
    },
    @{
        Name = 'Invalid version cannot rename files'
        Run = {
            param($directory)
            Assert-Rejected { & $ScriptPath -ReleaseDirectory $directory -Version '../0.6.4' } 'Invalid release version'
            Assert-True (Test-Path -LiteralPath (Join-Path $directory 'Amanu-stable-Setup.exe')) 'Invalid version changed the installer.'
        }
    },
    @{
        Name = 'Repeated finalization preserves installer and checksum bytes'
        Run = {
            param($directory)
            & $ScriptPath -ReleaseDirectory $directory -Version '0.6.4' | Out-Null
            $checksums = [IO.File]::ReadAllText((Join-Path $directory 'SHA256SUMS'))
            $result = & $ScriptPath -ReleaseDirectory $directory -Version '0.6.4'
            Assert-True ($result -eq (Join-Path $directory 'Amanu-0.6.4-Setup.exe')) 'Repeated finalization changed the filename.'
            Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'SHA256SUMS')) -eq $checksums) 'Repeated finalization changed checksums.'
        }
    }
)

$failed = 0
foreach ($test in $tests) {
    $directory = New-ReleaseFixture
    try {
        & $test.Run $directory
        Write-Host "PASS: $($test.Name)"
    } catch {
        $failed++
        Write-Host "FAIL: $($test.Name): $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
if ($failed -gt 0) { throw "$failed installer naming test(s) failed." }
Write-Host "$($tests.Count) installer naming tests passed."
