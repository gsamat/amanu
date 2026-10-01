param([Parameter(Mandatory = $true)][string]$PublishDirectory)

$ErrorActionPreference = "Stop"
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "Building the live runtime requires CMake and the MSVC C++ build tools on Windows."
}
$sourceCommit = "4807edaf210d0d7e8a6f7fb2a44b65966a2797f0"
$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ("amanu-live-" + [Guid]::NewGuid().ToString("N"))
$sourceDirectory = Join-Path $workDirectory "source"
$buildDirectory = Join-Path $workDirectory "build"
$destinationDirectory = Join-Path $PublishDirectory "live-runtime"
try {
    git clone --depth 1 --branch v0.2.4 https://github.com/handy-computer/transcribe.cpp.git $sourceDirectory
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch the streaming runtime." }
    $actualCommit = (git -C $sourceDirectory rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $sourceCommit) { throw "Streaming runtime commit mismatch." }
    # Separate from the pinned final-transcript CLI. Static CRT needs no VC++ installer.
    # Dispatch among CPU variants at runtime instead of targeting the build host's CPU.
    cmake -S $sourceDirectory -B $buildDirectory `
        -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF `
        -DTRANSCRIBE_BUILD_SHARED=ON -DTRANSCRIBE_GGML_BACKEND_DL=ON `
        -DTRANSCRIBE_VULKAN=OFF -DTRANSCRIBE_USE_OPENMP=OFF -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF `
        -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    if ($LASTEXITCODE -ne 0) { throw "Could not configure the streaming runtime." }
    cmake --build $buildDirectory --config Release --parallel 2
    if ($LASTEXITCODE -ne 0) { throw "Could not build the streaming runtime." }
    $libraries = @(Get-ChildItem -LiteralPath $buildDirectory -Filter '*.dll' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]Release[\\/]' })
    if (-not ($libraries | Where-Object Name -eq 'transcribe.dll')) { throw "No streaming DLL was built." }
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    $libraries | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $destinationDirectory -Force }
    $licenses = Join-Path $destinationDirectory 'licenses'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceDirectory 'LICENSE') -Destination (Join-Path $licenses 'transcribe.cpp-LICENSE') -Force
    Copy-Item -LiteralPath (Join-Path $sourceDirectory 'ggml/LICENSE') -Destination (Join-Path $licenses 'ggml-LICENSE') -Force
    Write-Host "Bundled streaming runtime from $actualCommit"
}
finally {
    # Only the unique temporary directory created by this invocation is removed.
    if ([IO.Path]::GetFullPath($workDirectory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
