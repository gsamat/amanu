param(
    [Parameter(Mandatory = $true)]
    [string]$PublishDirectory,
    # The release workflow passes this so a runner that lost the Vulkan SDK
    # fails the build instead of quietly shipping a processor-only runtime.
    [switch]$RequireVulkan
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "Building the local runtime requires CMake and the MSVC C++ build tools on Windows."
}
# The Vulkan module is loaded at runtime like the CPU variants. On a computer
# without a Vulkan driver it does not load and the CLI keeps to the processor,
# so one package serves every machine. Building it needs the Vulkan SDK.
$vulkan = -not [string]::IsNullOrWhiteSpace($env:VULKAN_SDK) -and (Test-Path -LiteralPath $env:VULKAN_SDK)
if ($RequireVulkan -and -not $vulkan) {
    throw "The release runtime needs the Vulkan SDK; VULKAN_SDK is not set to an existing directory."
}
if (-not $vulkan) {
    Write-Warning "VULKAN_SDK is not set: building a processor-only local runtime."
}
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

    # The pinned CLI initializes modules only for --list-devices. Model loads
    # in ordinary and batch passes need the same bootstrap.
    $bootstrapPatch = Join-Path $PSScriptRoot '../patches/transcribe-cli-init-backends.patch'
    git -C $sourceDirectory apply --ignore-space-change $bootstrapPatch
    if ($LASTEXITCODE -ne 0) { throw "Could not apply the pinned CLI backend initialization patch." }

    # The library takes UTF-8 paths, but Windows narrow argv and fopen use ACP.
    $unicodePatch = Join-Path $PSScriptRoot '../patches/transcribe-cli-unicode-paths.patch'
    git -C $sourceDirectory apply --ignore-space-change $unicodePatch
    if ($LASTEXITCODE -ne 0) { throw "Could not apply the pinned CLI Unicode path patch." }

    cmake -S $sourceDirectory -B $buildDirectory `
        -DTRANSCRIBE_BUILD_TESTS=OFF `
        -DTRANSCRIBE_BUILD_TOOLS=OFF `
        -DTRANSCRIBE_BUILD_SHARED=ON `
        -DTRANSCRIBE_GGML_BACKEND_DL=ON `
        "-DTRANSCRIBE_VULKAN=$(if ($vulkan) { 'ON' } else { 'OFF' })" `
        -DTRANSCRIBE_USE_OPENMP=OFF `
        -DGGML_NATIVE=OFF `
        -DGGML_CPU_ALL_VARIANTS=ON `
        -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    if ($LASTEXITCODE -ne 0) { throw "Could not configure transcribe-cli." }
    # Build the CPU modules too. Runtime dispatch selects instructions supported
    # by the user's processor instead of assuming the CI runner's CPU features.
    cmake --build $buildDirectory --config Release --parallel 2
    if ($LASTEXITCODE -ne 0) { throw "Could not build transcribe-cli." }

    $cli = Get-ChildItem -LiteralPath $buildDirectory -Filter transcribe-cli.exe -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
        Select-Object -First 1
    if ($null -eq $cli) { throw "The transcribe-cli build produced no Release executable." }
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    Copy-Item -LiteralPath $cli.FullName -Destination (Join-Path $destinationDirectory "transcribe-cli.exe") -Force
    Get-ChildItem -LiteralPath $buildDirectory -Filter '*.dll' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]Release[\\/]' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destinationDirectory -Force }
    if ($vulkan -and -not (Test-Path -LiteralPath (Join-Path $destinationDirectory "ggml-vulkan.dll"))) {
        throw "The Vulkan build produced no ggml-vulkan.dll."
    }
    $licenses = Join-Path $destinationDirectory "licenses"
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "LICENSE") -Destination (Join-Path $licenses "transcribe.cpp-LICENSE") -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory "ggml/LICENSE") -Destination (Join-Path $licenses "ggml-LICENSE") -Force
    & (Join-Path $PSScriptRoot 'Test-NativeCpu.ps1') -RuntimeDirectory $destinationDirectory
    & (Join-Path $PSScriptRoot '../tests/Test-NativeUnicodePaths.ps1') -RuntimeDirectory $destinationDirectory
    Write-Host "Bundled transcribe-cli from $actualCommit"
}
finally {
    if ([IO.Path]::GetFullPath($workDirectory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
