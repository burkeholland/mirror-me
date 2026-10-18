<#
.SYNOPSIS
Allows MirrorMe development and test executables through Windows Firewall.

.DESCRIPTION
Windows asks "Allow access to private and public networks?" the first time a
program at a new path listens on the network. Development builds and tests run
from many paths (every worktree has its own build folder), so the prompt keeps
coming back. This script adds inbound Allow rules (all profiles) for every
MirrorMe development and test executable it finds (the app, sender, native
test probes, and WinPlay test hosts), plus the fixed path the standalone
receiver test copies to. Toolchain and SDK executables are skipped. Store
installs do not need this: the MSIX manifest declares its own firewall rules.

All rules go in the "MirrorMe development" group. Rerun after building a new
worktree. Run elevated.

.PARAMETER RepositoryRoots
Checkouts to scan. Defaults to every git worktree of this repository.

.PARAMETER Remove
Deletes every rule in the "MirrorMe development" group instead.
#>
[CmdletBinding()]
param(
    [string[]]$RepositoryRoots,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"
$group = "MirrorMe development"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script from an elevated PowerShell window."
}

if ($Remove) {
    Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "Removed the '$group' firewall rules."
    return
}

if (-not $RepositoryRoots) {
    $repo = Split-Path -Parent $PSScriptRoot
    $RepositoryRoots = @($repo)
    $worktrees = & git -C $repo worktree list --porcelain 2>$null
    if ($LASTEXITCODE -eq 0) {
        $RepositoryRoots += @($worktrees | Where-Object { $_ -like "worktree *" } |
            ForEach-Object { $_.Substring(9).Replace("/", "\") })
    }
}

$programs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($env:LOCALAPPDATA) {
    # Fixed copy used by TestNativeApplicationRunsFromOneFile (native_binary_test.go).
    [void]$programs.Add((Join-Path $env:LOCALAPPDATA "MirrorMe\dev\standalone-check\MirrorMe.exe"))
}
foreach ($root in ($RepositoryRoots | Sort-Object -Unique)) {
    foreach ($folder in @("build", "sender\bin")) {
        $path = Join-Path $root $folder
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Get-ChildItem -LiteralPath $path -Recurse -Filter *.exe -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(CMakeFiles|obj|sdk|node_modules)\\' -and
                $_.Name -match '^(mirrorme.*|mDNSResponder|protocol_.*|media_.*|winplay|testhost)\.exe$' } |
            ForEach-Object { [void]$programs.Add($_.FullName) }
    }
}

$existing = @{}
foreach ($rule in @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)) {
    $program = ($rule | Get-NetFirewallApplicationFilter).Program
    if ($program) { $existing[$program.ToLowerInvariant()] = $true }
}

$added = 0
foreach ($program in ($programs | Sort-Object)) {
    if ($existing.ContainsKey($program.ToLowerInvariant())) { continue }
    New-NetFirewallRule -DisplayName "MirrorMe dev: $program" -Group $group -Direction Inbound `
        -Action Allow -Profile Any -Program $program | Out-Null
    $added++
}
Write-Host "Firewall: $added new rule(s), $($programs.Count) MirrorMe executable(s) allowed in '$group'."

# Block rules (created when a prompt was cancelled) win over Allow rules.
$blocked = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Program -and $programs.Contains($_.Program) } |
    Get-NetFirewallRule | Where-Object { $_.Action -eq "Block" -and $_.Enabled -eq "True" })
foreach ($rule in $blocked) {
    Write-Warning "Block rule '$($rule.DisplayName)' still blocks $(($rule | Get-NetFirewallApplicationFilter).Program)."
}
