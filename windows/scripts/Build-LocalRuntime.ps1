param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory
)

$ErrorActionPreference = "Stop"
$sourceCommit = "a94e021ef658dc7c788837341a13f6acea3baf3c"
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ("amanu-transcribe-" + [Guid]::NewGuid().ToString("N"))
$sourceDirectory = Join-Path $workDirectory "source"
$buildDirectory = Join-Path $workDirectory "build"
$destinationDirectory = Join-Path $PublishDirectory "local-runtime"

try {
    git clone --depth 1 --branch v0.1.3 https://github.com/handy-computer/transcribe.cpp.git $sourceDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch the pinned transcribe.cpp source." }
    $actualCommit = (git -C $sourceDirectory rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $sourceCommit) {
        throw "transcribe.cpp v0.1.3 did not resolve to the pinned commit."
    }

    cmake -S $sourceDirectory -B $buildDirectory `
        -DTRANSCRIBE_BUILD_TESTS=OFF `
        -DTRANSCRIBE_BUILD_TOOLS=OFF `
        -DTRANSCRIBE_BUILD_SHARED=OFF `
        -DTRANSCRIBE_VULKAN=OFF `
        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    if ($LASTEXITCODE -ne 0) { throw "Could not configure transcribe-cli." }
    cmake --build $buildDirectory --target transcribe-cli --config Release
    if ($LASTEXITCODE -ne 0) { throw "Could not build transcribe-cli." }

    $cli = Get-ChildItem -LiteralPath $buildDirectory -Filter transcribe-cli.exe -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
        Select-Object -First 1
    if ($null -eq $cli) { throw "The transcribe-cli build produced no Release executable." }
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    Copy-Item -LiteralPath $cli.FullName -Destination (Join-Path $destinationDirectory "transcribe-cli.exe") -Force
    $licenses = Join-Path $destinationDirectory "licenses"
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "LICENSE") -Destination (Join-Path $licenses "transcribe.cpp-LICENSE") -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "ggml/LICENSE") -Destination (Join-Path $licenses "ggml-LICENSE") -Force
    Write-Host "Bundled transcribe-cli from $actualCommit"
}
finally {
    if (Test-Path -LiteralPath $workDirectory) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
