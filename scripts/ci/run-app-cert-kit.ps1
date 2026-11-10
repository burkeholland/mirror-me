#Requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$Package,
    [int]$TimeoutMinutes = 20
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-Result([string]$Result) {
    Write-Host "App Certification Kit: $Result"
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value "### App Certification Kit`n`n$Result"
    Add-Content -LiteralPath "$env:RUNNER_TEMP\qa-checks.md" -Value "App Certification Kit: $Result"
}
$kit = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\App Certification Kit\appcert.exe'
if (-not (Test-Path -LiteralPath $kit -PathType Leaf)) {
    Write-Result 'NOT RUN: this runner image does not include appcert.exe.'
    return
}
$report = Join-Path $env:RUNNER_TEMP 'app-cert-report.xml'
& $kit reset | Out-Null
if ($LASTEXITCODE) { throw 'App Certification Kit reset failed.' }
$run = Start-Process -FilePath $kit -PassThru -NoNewWindow -ArgumentList @(
    'test', '-appxpackagepath', "`"$Package`"", '-reportoutputpath', "`"$report`"")
try {
    if (-not $run.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        Stop-Process -Id $run.Id -Force
        Write-Result "NOT FINISHED: no result after $TimeoutMinutes minutes."
        throw 'App Certification Kit timed out.'
    }
    if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
        Write-Result "NOT CHECKED: exit code $($run.ExitCode), no report."
        throw 'App Certification Kit did not produce a report.'
    }
    [xml]$xml = Get-Content -LiteralPath $report -Raw
    $overall = [string]$xml.REPORT.OVERALL_RESULT
    Write-Result "Overall: $overall; exit code $($run.ExitCode). This is a throwaway-signed development identity, not Store certification."
    if ($run.ExitCode -ne 0 -or $overall -notmatch '^(PASS|PASSED)$') {
        throw 'App Certification Kit did not pass; see the report artifact.'
    }
} finally { $run.Dispose() }
