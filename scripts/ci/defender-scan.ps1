#Requires -Version 7.2
param([Parameter(Mandatory)][string[]]$Paths)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Defender settings may only be changed on the disposable GitHub-hosted runner.'
}
function Write-Result([string]$Result) {
    Write-Host "Microsoft Defender: $Result"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "### Microsoft Defender`n`n$Result"
    Add-Content -LiteralPath "$env:RUNNER_TEMP\qa-checks.md" -Value "Microsoft Defender: $Result"
}
# Hosted images disable Defender. Never call a disabled scan a clean antivirus result.
try {
    Set-MpPreference -SubmitSamplesConsent NeverSend
    Set-MpPreference -DisableRealtimeMonitoring $false
    Start-Service -Name WinDefend
    Update-MpSignature -UpdateSource MicrosoftUpdateServer
    $status = Get-MpComputerStatus
} catch {
    Write-Result "NOT VERIFIED: hosted protection unavailable: $($_.Exception.Message). Local quarantine remains unresolved."
    return
}
if (-not $status.AntivirusEnabled -or -not $status.RealTimeProtectionEnabled -or
    $status.AMRunningMode -ne 'Normal') {
    Write-Result "NOT VERIFIED: mode $($status.AMRunningMode), antivirus $($status.AntivirusEnabled), real-time $($status.RealTimeProtectionEnabled)."
    return
}
$preferences = Get-MpPreference
if (@($preferences.ExclusionPath | Where-Object { $_ }).Count) {
    Write-Result 'NOT VERIFIED: runner has pre-existing scan exclusions. No exclusions were added or changed.'
    return
}
$tool = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
foreach ($path in $Paths) {
    & $tool -Scan -ScanType 3 -File $path
    if ($LASTEXITCODE) { throw "Defender scan failed or detected a threat (exit $LASTEXITCODE)." }
}
$detections = @(Get-MpThreatDetection)
if ($detections.Count) { throw 'Defender reported detections on the disposable runner.' }
Write-Result "Scan completed with signatures $($status.AntivirusSignatureVersion); no detections reported. This does not resolve or prove a false positive for the managed PC's quarantine."
