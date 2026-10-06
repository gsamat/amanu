param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $temporaryRoot ('amanu-unicode-' + [Guid]::NewGuid().ToString('N'))
$unicode = Join-Path $scratch 'Сотрудник 模型 café 😀'
$results = [Collections.Generic.List[object]]::new()
$failures = [Collections.Generic.List[string]]::new()

function Invoke-Cli([string]$Name, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $unicode 'transcribe-cli.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = [IO.MemoryStream]::new()
        $stderr = [IO.MemoryStream]::new()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw "$Name timed out." }
        [void]$outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
        $result = [pscustomobject]@{
            Name = $Name; Arguments = $Arguments; ExitCode = $process.ExitCode
            Stdout = [Text.Encoding]::UTF8.GetString($outBytes)
            Stderr = [Text.Encoding]::UTF8.GetString($errBytes)
        }
        $results.Add($result)
        if ($EvidenceDirectory) {
            [IO.File]::WriteAllBytes((Join-Path $EvidenceDirectory "$Name.stdout.txt"), $outBytes)
            [IO.File]::WriteAllBytes((Join-Path $EvidenceDirectory "$Name.stderr.txt"), $errBytes)
        }
        return $result
    } finally { $stdout.Dispose(); $stderr.Dispose(); $process.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $unicode -Force | Out-Null
    if ($EvidenceDirectory) { New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null }
    Get-ChildItem -LiteralPath $runtime -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $unicode }

    $asciiWav = Join-Path $scratch 'audio.wav'
    $unicodeWav = Join-Path $unicode 'запись 音声 😀.wav'
    $stream = [IO.File]::Create($asciiWav)
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $writer.Write([int]32036)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $writer.Write([int]16)
        $writer.Write([short]1); $writer.Write([short]1); $writer.Write([int]16000)
        $writer.Write([int]32000); $writer.Write([short]2); $writer.Write([short]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes('data')); $writer.Write([int]32000)
        $writer.Write([byte[]]::new(32000))
    } finally { $writer.Dispose() }
    Copy-Item -LiteralPath $asciiWav -Destination $unicodeWav
    $asciiModel = Join-Path $scratch 'model.gguf'
    $unicodeModel = Join-Path $unicode 'модель 模型 😀.gguf'
    [IO.File]::WriteAllBytes($asciiModel, [byte[]]@(0))
    Copy-Item -LiteralPath $asciiModel -Destination $unicodeModel
    $devices = Invoke-Cli 'devices' @('--list-devices')
    if ($devices.ExitCode -ne 0 -or $devices.Stdout -notmatch 'name=CPU') {
        $failures.Add('CPU backend discovery failed from a Unicode runtime directory.')
    }
    foreach ($case in @(
        @{Name='ascii'; Model=$asciiModel; Wav=$asciiWav},
        @{Name='model'; Model=$unicodeModel; Wav=$asciiWav},
        @{Name='wav'; Model=$asciiModel; Wav=$unicodeWav},
        @{Name='both'; Model=$unicodeModel; Wav=$unicodeWav}
    )) {
        $result = Invoke-Cli $case.Name @('--backend', 'cpu', '-m', $case.Model, $case.Wav)
        if ($result.ExitCode -eq 0 -or $result.Stderr -notmatch 'short read on file magic' -or
            -not $result.Stdout.Contains($case.Model) -or -not $result.Stdout.Contains($case.Wav)) {
            $failures.Add("$($case.Name): expected readable WAV and intact paths reaching GGUF short-read validation; got $($result.Stderr.Trim())")
        }
    }
    $list = Join-Path $unicode 'список 音声 😀.txt'
    [IO.File]::WriteAllText($list, $unicodeWav + "`n", [Text.UTF8Encoding]::new($false))
    $batch = Invoke-Cli 'batch-list' @('--backend', 'cpu', '-m', $asciiModel, '--batch', $list, '--batch-jsonl')
    if ($batch.ExitCode -eq 0 -or $batch.Stderr -notmatch 'short read on file magic') {
        $failures.Add("batch-list: Unicode list was not read before expected GGUF validation: $($batch.Stderr.Trim())")
    }
    if ($EvidenceDirectory) {
        $results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'results.json') -Encoding utf8
    }
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Host 'Native Unicode runtime, argv, model, WAV and batch-list paths verified (6 cases).'
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith($temporaryRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
