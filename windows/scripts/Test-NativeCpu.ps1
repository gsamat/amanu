param([Parameter(Mandatory = $true)][string]$RuntimeDirectory)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
function Invoke-Cli([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $runtime 'transcribe-cli.exe'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); throw 'Native CPU smoke test timed out.' }
        return @{ ExitCode=$process.ExitCode; Text=$stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
$devices = Invoke-Cli @('--list-devices')
if ($devices.ExitCode -ne 0 -or $devices.Text -notmatch 'name=CPU') { throw "Native runtime has no usable CPU device: $($devices.Text)" }
# Ordinary model-loading startup must also register modules. No model download
# is needed: a missing model should fail after CPU initialization.
$missing = Join-Path ([IO.Path]::GetTempPath()) ('amanu-missing-' + [Guid]::NewGuid().ToString('N') + '.gguf')
$normal = Invoke-Cli @('--backend', 'cpu', '-m', $missing, $missing)
if ($normal.ExitCode -eq 0 -or $normal.Text -notmatch 'transcribe_init_backends: .*CPU') {
    throw "Ordinary CLI startup did not initialize CPU modules: $($normal.Text)"
}
Write-Host 'Native CPU dispatch and ordinary CLI initialization verified.'
