param(
    [Parameter(Mandatory = $true)] [string] $PublishDirectory,
    [Parameter(Mandatory = $true)] [string] $ReleaseDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-CompanySignature([string] $Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Invalid Authenticode signature for ${Path}: $($signature.Status)"
    }
    if ($signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Fands Software LLC(,|$)') {
        throw "Unexpected publisher for ${Path}: $($signature.SignerCertificate.Subject)"
    }
    if ($null -eq $signature.TimeStamperCertificate) {
        throw "Missing Authenticode timestamp for ${Path}"
    }
    Write-Host "Verified ${Path}: $($signature.SignerCertificate.Subject), timestamp present"
}

$payloadPaths = @('Amanu.exe', 'Amanu.dll', 'Amanu.Core.dll', 'local-runtime/transcribe-cli.exe')
foreach ($relativePath in $payloadPaths) {
    Assert-CompanySignature (Join-Path $PublishDirectory $relativePath)
}
Assert-CompanySignature (Join-Path $ReleaseDirectory 'Amanu-beta-Setup.exe')

$packages = @(Get-ChildItem -LiteralPath $ReleaseDirectory -File | Where-Object {
    $_.Name -like '*-full.nupkg' -or $_.Name -like '*-Portable.zip'
})
if ($packages.Count -ne 2) {
    throw "Expected one full update package and one portable ZIP; found $($packages.Count)"
}

foreach ($package in $packages) {
    $extractPath = Join-Path $env:RUNNER_TEMP "amanu-signature-check-$($package.Name)"
    [IO.Compression.ZipFile]::ExtractToDirectory($package.FullName, $extractPath)
    $requiredNames = @('Amanu.exe', 'Amanu.dll', 'Amanu.Core.dll', 'transcribe-cli.exe')
    if ($package.Extension -eq '.nupkg') {
        $requiredNames += @('Squirrel.exe', 'Amanu_ExecutionStub.exe')
    } else {
        $requiredNames += 'Update.exe'
    }
    $files = @(Get-ChildItem -LiteralPath $extractPath -Recurse -File | Where-Object {
        $_.Name -in $requiredNames
    })
    foreach ($name in $requiredNames) {
        if (@($files | Where-Object { $_.Name -eq $name }).Count -eq 0) {
            throw "Missing ${name} in $($package.Name)"
        }
    }
    foreach ($file in $files) {
        Assert-CompanySignature $file.FullName
    }
}
