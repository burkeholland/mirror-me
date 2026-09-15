[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$TestDirectory,
    [int]$Cycles = 3
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Executable = (Resolve-Path -LiteralPath $Executable).Path
if (Test-Path -LiteralPath $TestDirectory) { throw "Test directory already exists: $TestDirectory" }
$null = New-Item -ItemType Directory -Path $TestDirectory
$TestDirectory = (Resolve-Path -LiteralPath $TestDirectory).Path
$startupEntry = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupEnabled = [bool]($startupEntry.PSObject.Properties['MirrorMe'] -and $startupEntry.MirrorMe)
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MirrorMeLifecycleWindows {
    public delegate bool EnumWindow(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr handle, StringBuilder name, int length);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr handle, uint message, UIntPtr wparam, IntPtr lparam);
    public static IntPtr TrayWindow(uint process) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((handle, parameter) => {
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner == process) {
                var name = new StringBuilder(256);
                GetClassName(handle, name, name.Capacity);
                if (name.ToString() == "MirrorMeTrayWindow") { result = handle; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
    $profile = Join-Path $TestDirectory "cycle-$cycle"
    $settingsDirectory = Join-Path $profile 'MirrorMe'
    $null = New-Item -ItemType Directory -Path $settingsDirectory -Force
    @{
        deviceName = 'MirrorMe installation test'; resolution = 'auto'; maxFps = 30
        audioEnabled = $true; hardwareDecode = $false; h265 = $false
        preferNewestConnection = $true; idleTimeoutSeconds = 15
        requirePin = $false; pinCode = ''; launchAtStartup = $startupEnabled
        startMinimized = $false; autoStartMirroring = ($cycle -gt 1)
        alwaysOnTop = $false; theme = 'system'; firstRun = ($cycle -eq 1)
        verboseLogging = $true
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settingsDirectory 'settings.json')
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.Environment['APPDATA'] = $profile
    $start.Environment['LOCALAPPDATA'] = $profile
    $app = [Diagnostics.Process]::Start($start)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            if ($app.HasExited) { throw "App exited before startup: $($app.ExitCode)" }
            $tray = [MirrorMeLifecycleWindows]::TrayWindow($app.Id)
            if ($tray -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($tray -eq [IntPtr]::Zero) { throw 'App did not create its tray window.' }
        Start-Sleep -Seconds 3
        $workers = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($app.Id)" |
            Where-Object { $_.ExecutablePath -eq $Executable -and $_.CommandLine -match '--receiver-worker' })
        if ($cycle -gt 1 -and $workers.Count -ne 1) { throw 'App did not start exactly one receiver worker.' }
        if (-not [MirrorMeLifecycleWindows]::PostMessage($tray, 0x0111, [UIntPtr]6, [IntPtr]::Zero)) {
            throw "Could not request Quit: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        if (-not $app.WaitForExit(15000)) { throw "Quit left control process $($app.Id) running." }
        if ($app.ExitCode -ne 0) { throw "App exited with code $($app.ExitCode)." }
        foreach ($worker in $workers) {
            if (Get-Process -Id $worker.ProcessId -ErrorAction SilentlyContinue) {
                throw "Quit left receiver process $($worker.ProcessId) running."
            }
        }
        Write-Host "Lifecycle cycle $cycle passed: launch, receiver state, Quit, and process cleanup."
    } finally {
        if (-not $app.HasExited) { $app.Kill($true); $app.WaitForExit() }
        $app.Dispose()
    }
}
