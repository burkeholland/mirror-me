#Requires -Version 7.2
# Runs a Store release in the required order: tag and source release first, then
# the package built from that exact main commit. It never uploads or submits.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IdentityName,
    [Parameter(Mandatory)][string]$Publisher,
    [Parameter(Mandatory)][string]$PublisherDisplayName,
    [Parameter(Mandatory)][string]$ProductDisplayName,
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin',
    [string]$Repository = 'burkeholland/mirror-me',
    [string]$OutputPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

function Get-Commit([string]$Revision) {
    $commit = (& git rev-parse "$Revision^{commit}").Trim()
    if ($LASTEXITCODE -ne 0 -or -not $commit) { throw "Could not resolve $Revision." }
    return $commit
}

function Assert-CleanSource([string]$When) {
    $status = @(& git status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the source tree.' }
    $changes = @($status | Where-Object { $_ -notmatch '^\?\? build[\\/]' })
    if ($changes.Count) { throw "The source tree must be clean $When`: $($changes -join '; ')" }
}

function Test-NativeBuildCurrent([string]$Commit) {
    $manifestPath = Join-Path $root 'build\native\link-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return $false }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    return $manifest.PSObject.Properties['sourceCommit'] -and $manifest.sourceCommit -eq $Commit -and
        $manifest.sourceTreeClean -and $manifest.production
}

Push-Location $root
try {
    Assert-CleanSource 'before a release'
    & git fetch --quiet origin main
    if ($LASTEXITCODE -ne 0) { throw 'Could not fetch origin/main.' }
    $commit = Get-Commit 'HEAD'
    if ($commit -ne (Get-Commit 'origin/main')) {
        throw "Store releases are built from main. HEAD is $commit, not origin/main."
    }
    $version = [string](Get-Content -LiteralPath 'wails.json' -Raw | ConvertFrom-Json).info.productVersion
    $tag = "v$version-preview.1"
    $sourceUrl = "https://github.com/$Repository/releases/tag/$tag"

    # A retried release keeps the native archive whose hash it already published.
    if (-not (Test-NativeBuildCurrent $commit)) {
        & (Join-Path $PSScriptRoot 'build-app.ps1') -ToolchainDirectory $ToolchainDirectory -NativeOnly
        Assert-CleanSource 'after the native build'
    }
    & (Join-Path $PSScriptRoot 'publish-source-release.ps1') -ApplicationVersion $version `
        -SourceCommit $commit -ToolchainDirectory $ToolchainDirectory -Repository $Repository
    Assert-CleanSource 'after publishing the source release'

    $package = @{
        StoreSubmission = $true
        BuildApplication = $true
        IdentityName = $IdentityName
        Publisher = $Publisher
        PublisherDisplayName = $PublisherDisplayName
        ProductDisplayName = $ProductDisplayName
        ToolchainDirectory = $ToolchainDirectory
    }
    if ($OutputPath) { $package.OutputPath = $OutputPath }
    if ($Force) { $package.Force = $true }
    & (Join-Path $PSScriptRoot 'build-msix.ps1') @package

    if (-not $OutputPath) { $OutputPath = "build\msix\MirrorMe-$version-windows-x64.msix" }
    if (-not [IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $root $OutputPath }
    $receipt = Get-Content -LiteralPath "$OutputPath.json" -Raw | ConvertFrom-Json
    $packageHash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $receipt.distributionApproved -or $receipt.sourceCommit -ne $commit -or
        $receipt.packageSha256 -ne $packageHash) {
        throw 'The MSIX receipt does not approve this package for this commit.'
    }
    if ((Get-Commit $tag) -ne $commit) { throw "$tag does not point at $commit." }
    Assert-CleanSource 'after the Store build'
    $response = Invoke-WebRequest -Uri $sourceUrl -Method Head -SkipHttpErrorCheck
    if ($response.StatusCode -ne 200) { throw "The source link returned $($response.StatusCode): $sourceUrl" }

    Write-Host "Ready for Partner Center. This script did not upload or submit anything."
    Write-Host "Package: $OutputPath"
    Write-Host "SHA-256: $packageHash"
    Write-Host "Version: $($receipt.packageVersion) ($version)"
    Write-Host "Identity: $($receipt.identityName) / $($receipt.publisher)"
    Write-Host "Commit: $commit"
    Write-Host "Source: $sourceUrl"
} finally {
    Pop-Location
}
