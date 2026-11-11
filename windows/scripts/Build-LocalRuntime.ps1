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
# The Vulkan module is loaded at runtime like the CPU variants and ships in a
# second runtime directory (see below). Users need no SDK: the Vulkan loader
# comes with Windows GPU drivers. Building it needs the Vulkan SDK's glslc.
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
    $libraries = Get-ChildItem -LiteralPath $buildDirectory -Filter '*.dll' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]Release[\\/]' }
    if ($vulkan -and -not ($libraries | Where-Object Name -eq 'ggml-vulkan.dll')) {
        throw "The Vulkan build produced no ggml-vulkan.dll."
    }
    # One build, two directories. The CLI loads every ggml module beside it at
    # startup whatever --backend says, so a Vulkan driver that crashes while
    # being enumerated would take the processor retry down with it. The
    # processor runtime therefore never holds ggml-vulkan.dll; the GPU runtime
    # is the same files plus that module.
    $runtimes = @(@{ Directory = $destinationDirectory; Vulkan = $false })
    if ($vulkan) { $runtimes += @{ Directory = (Join-Path $PublishDirectory "local-runtime-gpu"); Vulkan = $true } }
    foreach ($runtime in $runtimes) {
        New-Item -ItemType Directory -Force -Path $runtime.Directory | Out-Null
        Copy-Item -LiteralPath $cli.FullName -Destination (Join-Path $runtime.Directory "transcribe-cli.exe") -Force
        $libraries | Where-Object { $runtime.Vulkan -or $_.Name -ne 'ggml-vulkan.dll' } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $runtime.Directory -Force }
        $licenses = Join-Path $runtime.Directory "licenses"
        New-Item -ItemType Directory -Force -Path $licenses | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceDirectory "LICENSE") -Destination (Join-Path $licenses "transcribe.cpp-LICENSE") -Force
        Copy-Item -LiteralPath (Join-Path $sourceDirectory "ggml/LICENSE") -Destination (Join-Path $licenses "ggml-LICENSE") -Force
        # Build runners have no GPU, so the GPU runtime must still start on the
        # processor alone; that is also what a machine without Vulkan sees.
        & (Join-Path $PSScriptRoot 'Test-NativeCpu.ps1') -RuntimeDirectory $runtime.Directory
    }
    & (Join-Path $PSScriptRoot '../tests/Test-NativeUnicodePaths.ps1') -RuntimeDirectory $destinationDirectory
    Write-Host "Bundled transcribe-cli from $actualCommit"
}
finally {
    if ([IO.Path]::GetFullPath($workDirectory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
