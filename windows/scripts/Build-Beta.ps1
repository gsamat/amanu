param(
    [Parameter(Mandatory = $false)]
    [string]$Version = "0.6.0-beta.11",

    [Parameter(Mandatory = $false)]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false)]
    [string]$CertificatePassword
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$publishDirectory = Join-Path $windowsRoot "artifacts\publish"
$releaseDirectory = Join-Path $windowsRoot "artifacts\release"
$toolDirectory = Join-Path $windowsRoot ".tools"

dotnet restore (Join-Path $windowsRoot "Amanu.Windows.slnx")
dotnet test (Join-Path $windowsRoot "tests\Amanu.Core.Tests\Amanu.Core.Tests.csproj") --configuration Release --no-restore
dotnet publish (Join-Path $windowsRoot "src\Amanu.App\Amanu.App.csproj") `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --property:Version=$Version `
    --output $publishDirectory
& (Join-Path $PSScriptRoot "Build-LocalRuntime.ps1") -PublishDirectory $publishDirectory

if (-not (Test-Path (Join-Path $toolDirectory "vpk.exe"))) {
    dotnet tool install --tool-path $toolDirectory vpk --version 1.2.0
}

$arguments = @(
    "pack",
    "--packId", "Amanu",
    "--packVersion", $Version,
    "--packDir", $publishDirectory,
    "--mainExe", "Amanu.exe",
    "--packTitle", "Amanu Beta",
    "--packAuthors", "Amanu",
    "--icon", (Join-Path $windowsRoot "src\Amanu.App\Assets\Amanu.ico"),
    "--channel", "beta",
    "--runtime", "win-x64",
    "--releaseNotes", (Join-Path $windowsRoot "BETA.md"),
    "--outputDir", $releaseDirectory
)

if ($CertificatePath) {
    $fullCertificatePath = (Resolve-Path $CertificatePath).Path
    $arguments += @(
        "--signParams",
        "/td sha256 /fd sha256 /f `"$fullCertificatePath`" /p `"$CertificatePassword`" /tr http://timestamp.digicert.com"
    )
}

& (Join-Path $toolDirectory "vpk.exe") @arguments
Write-Host "Amanu beta artifacts: $releaseDirectory"
