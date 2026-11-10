#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Certificate,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-Result([string]$Check, [string]$Result) {
    Write-Host "$Check`: $Result"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "| $Check | $Result |"
    Add-Content -LiteralPath "$env:RUNNER_TEMP\qa-checks.md" -Value "| MSIX: $Check | $Result |"
}
Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "### Real MSIX install`n`n| Check | Result |`n|---|---|"
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MirrorMeInstallWindows {
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
$trusted = Import-Certificate -FilePath $Certificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
$installed = $null
$app = $null
try {
    Add-AppxPackage -Path $Package
    $packages = @(Get-AppxPackage -Name 'BurkeHolland.MirrorMe.Development')
    if ($packages.Count -ne 1) { throw 'The MSIX did not install.' }
    $installed = $packages[0]
    $location = $installed.InstallLocation
    if ($installed.IsDevelopmentMode -or $location -notlike '*\WindowsApps\*') {
        throw 'Expected a real install under WindowsApps, not developer registration.'
    }
    Write-Result 'Installed from the MSIX' "version $($installed.Version), signature $($installed.SignatureKind), under WindowsApps"
    $started = Get-Date
    Start-Process "shell:AppsFolder\$($installed.PackageFamilyName)!MirrorMe"
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $app -and (Get-Date) -lt $deadline) {
        $app = Get-Process -Name MirrorMe -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like "$location\*" -and $_.StartTime -ge $started.AddSeconds(-2) -and $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if (-not $app) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $app) { throw 'The installed app did not open a window within 60 seconds.' }
    $tray = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(30)
    while ($tray -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        $tray = [MirrorMeInstallWindows]::TrayWindow($app.Id)
        if ($tray -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
    }
    if ($tray -eq [IntPtr]::Zero) { throw 'The installed app did not create its tray window.' }
    Write-Result 'Launched from WindowsApps' 'window and tray window created'

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $automation = [Windows.Automation.AutomationElement]
    $byProcess = [Windows.Automation.PropertyCondition]::new($automation::ProcessIdProperty, $app.Id)
    $window = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $byProcess)
    if (-not $window) {
        Write-Result 'Help & about' 'NOT CHECKED: no accessible desktop window on this runner'
    } else {
        function Find-Named([string]$Name) {
            $condition = [Windows.Automation.PropertyCondition]::new($automation::NameProperty, $Name)
            $limit = (Get-Date).AddSeconds(45)
            while ((Get-Date) -lt $limit) {
                $found = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
                if ($found) { return $found }
                Start-Sleep -Milliseconds 500
            }
            throw "'$Name' was not found"
        }
        function Invoke-Named([string]$Name) {
            (Find-Named $Name).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            Start-Sleep -Milliseconds 700
        }
        Invoke-Named 'Help & about'
        Invoke-Named 'Built with open source'
        $page = (@($window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) |
            ForEach-Object { $_.Current.Name })) -join "`n"
        foreach ($expected in "Version $Version", 'Copyright', 'without warranty', 'GNU GPL version 3', 'not affiliated',
            'View the GPLv3 license', "Source for $Version") {
            if ($page -notmatch [regex]::Escape($expected)) { throw "Help & about does not show '$expected'" }
        }
        Write-Result 'Help & about' "version $Version, copyright, no-warranty, GPL and Apple attribution rendered"
    }

    if (-not [MirrorMeInstallWindows]::PostMessage($tray, 0x0111, [UIntPtr]6, [IntPtr]::Zero)) { throw 'Could not request Quit.' }
    if (-not $app.WaitForExit(20000)) { throw 'Quit left the app running.' }
    if ($app.ExitCode -ne 0) { throw "App exited with code $($app.ExitCode)." }
    Start-Sleep -Seconds 2
    $left = @(Get-Process -Name MirrorMe, MirrorMe.Sender -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$location\*" })
    if ($left.Count) { throw "Quit left $($left.Count) process(es) running." }
    Write-Result 'Quit' 'clean exit, no app or sender processes left'
} finally {
    if ($app) {
        if (-not $app.HasExited) { $app.Kill($true); $app.WaitForExit() }
        $app.Dispose()
    }
    if ($installed) {
        Remove-AppxPackage -Package $installed.PackageFullName
        Write-Result 'Uninstalled' 'yes'
    }
    Remove-Item -LiteralPath $trusted.PSPath
}
