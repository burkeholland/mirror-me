#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$directory = Join-Path $env:RUNNER_TEMP 'qa-msix'
$path = Join-Path $directory 'MirrorMe-QA.msix'
$receipt = Get-Content -LiteralPath "$path.json" -Raw | ConvertFrom-Json
$commit = (& git rev-parse HEAD).Trim()
if ($LASTEXITCODE) { throw 'Could not identify QA source commit.' }
$record = [ordered]@{
    sourceCommit = $commit
    runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    applicationVersion = $receipt.applicationVersion
    packageVersion = $receipt.packageVersion
    identityName = $receipt.identityName
    packageSha256 = $receipt.packageSha256
    executableSha256 = $receipt.executableSha256
    senderExecutableSha256 = $receipt.senderExecutableSha256
    distributionApproved = $false
    physicalIPhoneVerified = $false
    note = 'QA only. Throwaway certificate; not a Store release or antivirus clearance. Source tag remains unpublished.'
}
$record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'build-record.json') -Encoding utf8NoBOM
# The original receipt contains runner paths; retain the hashes and provenance above.
Remove-Item -LiteralPath "$path.json"
Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @"
### QA package

Commit: $commit

MSIX SHA-256: $($receipt.packageSha256)

Development identity, throwaway-signed. Physical iPhone test, merge, source release and Store submission remain on hold.
"@
