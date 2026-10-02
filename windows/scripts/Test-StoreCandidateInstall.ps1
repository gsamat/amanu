param([Parameter(Mandatory)] [string] $Installer, [Parameter(Mandatory)] [string] $ReportDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run only on a disposable GitHub Windows runner, never a user profile.' }
foreach ($path in @((Join-Path $env:LOCALAPPDATA 'Amanu'), (Join-Path $env:LOCALAPPDATA 'Amanu Data'))) {
    if (Test-Path -LiteralPath $path) { throw "Profile is not clean: $path" }
}
$root = Join-Path $env:RUNNER_TEMP ('store-install-' + [Guid]::NewGuid().ToString('N'))
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class StoreWindows {
    delegate bool Callback(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr parameter);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    public static string[] VisibleCandidateWindows() {
        var found = new List<string>();
        EnumWindows((hwnd, parameter) => {
            if (IsWindowVisible(hwnd)) {
                uint pid; GetWindowThreadProcessId(hwnd, out pid);
                try {
                    var name = Process.GetProcessById((int)pid).ProcessName;
                    if (name == "Amanu" || name == "Update" || name == "Amanu-0.6.3-Setup") found.Add(name + ":" + pid);
                } catch (ArgumentException) { }
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
function Run-Quiet([string] $File, [string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($File)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $visible = [Collections.Generic.HashSet[string]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        foreach ($window in [StoreWindows]::VisibleCandidateWindows()) { [void]$visible.Add($window) }
        if ($timer.Elapsed.TotalSeconds -gt 120) { $process.Kill($true); throw 'Installer operation timed out.' }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    } while (-not $process.HasExited)
    $process.WaitForExit()
    $result = [pscustomobject]@{ ExitCode = $process.ExitCode; VisibleWindows = @($visible); ElapsedSeconds = $timer.Elapsed.TotalSeconds }
    if ($result.ExitCode -ne 0 -or $visible.Count -gt 0) { $result | ConvertTo-Json | Write-Host; throw 'Quiet operation failed or displayed UI.' }
    return $result
}
$rule = 'AmanuStoreCandidate-' + [Guid]::NewGuid().ToString('N')
try {
    New-NetFirewallRule -DisplayName $rule -Direction Outbound -Program ([IO.Path]::GetFullPath($Installer)) -Action Block | Out-Null
    $install = Run-Quiet $Installer @('--silent', '--installto', $root)
    if (-not (Test-Path -LiteralPath (Join-Path $root 'current/Amanu.exe'))) { throw 'Installed payload missing.' }
    Start-Sleep -Seconds 2
    if (Get-Process Amanu -ErrorAction SilentlyContinue) { throw 'Silent setup auto-launched Amanu.' }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Amanu Data')) { throw 'Silent setup initialized application settings.' }
    & (Join-Path $PSScriptRoot 'Get-PeSignatureInventory.ps1') -Directory $root -Output (Join-Path $ReportDirectory 'installed-pe.json') -RequireValid
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $root 'current/Amanu.dll')).ProductVersion
    if ($version -notlike '0.6.3*') { throw "Incorrect installed version: $version" }
    $uninstall = Run-Quiet (Join-Path $root 'Update.exe') @('uninstall', '--silent')
    Start-Sleep -Seconds 5
    if (Test-Path -LiteralPath (Join-Path $root 'current/Amanu.exe')) { throw 'Uninstall left the application installed.' }
    $entry = Get-ItemProperty 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Uninstall/Amanu' -ErrorAction SilentlyContinue
    if ($entry) { throw 'Uninstall left its registry entry.' }
    [pscustomobject]@{
        Host = [Environment]::OSVersion.VersionString; Profile = $env:USERNAME; Version = $version
        InstallerSha256 = (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash
        Install = $install; Uninstall = $uninstall; AutoLaunch = $false; InstallerNetworkBlocked = $true
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'quiet-install.json') -Encoding utf8
} finally { Remove-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue }
