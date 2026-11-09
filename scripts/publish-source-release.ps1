#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ApplicationVersion,
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceCommit = '',
    [string]$ReferenceSourceZip = '',
    [string]$ReferenceSourceTag = 'v0.2.4-preview.1',
    [string]$ReferenceSourceSha256 = '4fab1d0a86111ecefef0a53767bb931d147da2191846334e02aefcd1bcf38b8a',
    [string]$StorePackageVersion = '',
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin',
    [string]$Repository = 'burkeholland/mirror-me'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Get-RemoteTagCommit([string]$Tag) {
    $lines = @(& git ls-remote --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}")
    if ($LASTEXITCODE -ne 0) { throw "Could not query remote tag $Tag." }
    $direct = ''
    $peeled = ''
    foreach ($line in $lines) {
        $fields = $line -split "`t", 2
        if ($fields.Count -ne 2) { continue }
        if ($fields[1] -eq "refs/tags/$Tag^{}") { $peeled = $fields[0] }
        elseif ($fields[1] -eq "refs/tags/$Tag") { $direct = $fields[0] }
    }
    if ($peeled) { return $peeled }
    return $direct
}

Push-Location $root
try {
    foreach ($tool in @('git', 'gh')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Source release publishing requires '$tool'."
        }
    }
    if (-not $SourceCommit) {
        $SourceCommit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $SourceCommit) {
            throw 'Could not identify the application source commit.'
        }
    }
    $SourceCommit = $SourceCommit.ToLowerInvariant()
    & git cat-file -e "$SourceCommit^{commit}"
    if ($LASTEXITCODE -ne 0) {
        throw "Application source commit is unavailable: $SourceCommit"
    }

    $tag = "v$ApplicationVersion-preview.1"
    $outputDirectory = Join-Path $root "build\source-release\$ApplicationVersion"
    $archivePath = Join-Path $outputDirectory "MirrorMe-$ApplicationVersion-source.zip"
    $manifestPath = Join-Path $outputDirectory 'release-manifest.json'
    $checksumsPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory 'release-notes.md'))) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }
    $notesPath = Join-Path $outputDirectory 'release-notes.md'

    $existingOutput = @(& gh release view $tag --repo $Repository --json tagName 2>&1)
    $existingExitCode = $LASTEXITCODE
    if ($existingExitCode -eq 0) {
        & (Join-Path $PSScriptRoot 'verify-source-release.ps1') `
            -ApplicationVersion $ApplicationVersion -ExpectedCommit $SourceCommit -Repository $Repository
        return
    }
    if (($existingOutput -join "`n") -notmatch '(?i)(not found|HTTP 404|release not found)') {
        throw "Could not determine whether GitHub release $tag already exists: $($existingOutput -join ' ')"
    }

    $packageArguments = @(
        '-ApplicationVersion', $ApplicationVersion,
        '-SourceCommit', $SourceCommit,
        '-ToolchainDirectory', $ToolchainDirectory,
        '-Force'
    )
    if ($ReferenceSourceZip) {
        if (-not [IO.Path]::IsPathRooted($ReferenceSourceZip)) {
            $ReferenceSourceZip = Join-Path $root $ReferenceSourceZip
        }
        if (-not (Test-Path -LiteralPath $ReferenceSourceZip -PathType Leaf)) {
            throw "Reference source archive is missing: $ReferenceSourceZip"
        }
        $packageArguments += @(
            '-ReferenceSourceZip', $ReferenceSourceZip,
            '-ReferenceSourceTag', $ReferenceSourceTag,
            '-ReferenceSourceSha256', $ReferenceSourceSha256
        )
    }
    # Always regenerate until the release exists, so a stale package can never be published.
    & (Join-Path $PSScriptRoot 'package-source-release.ps1') @packageArguments
    & (Join-Path $PSScriptRoot 'verify-source-release.ps1') `
        -ApplicationVersion $ApplicationVersion -ExpectedCommit $SourceCommit `
        -LocalOnly -LocalArchivePath $archivePath

    $remoteCommit = Get-RemoteTagCommit $tag
    if ($remoteCommit -and $remoteCommit -ne $SourceCommit) {
        throw "Remote tag $tag already points to $remoteCommit, not $SourceCommit."
    }
    $localCommit = (& git rev-parse "$tag^{commit}" 2>$null).Trim()
    if ($LASTEXITCODE -eq 0 -and $localCommit -ne $SourceCommit) {
        throw "Local tag $tag already points to $localCommit, not $SourceCommit."
    }
    if (-not $remoteCommit) {
        if ($LASTEXITCODE -ne 0) {
            & git tag -a $tag $SourceCommit -m "MirrorMe $ApplicationVersion source release"
            if ($LASTEXITCODE -ne 0) { throw "Could not create source tag $tag." }
        }
        Invoke-Checked 'git' @('push', 'origin', "refs/tags/$tag")
    } elseif ($LASTEXITCODE -ne 0) {
        Invoke-Checked 'git' @('fetch', '--no-tags', 'origin', "refs/tags/${tag}:refs/tags/$tag")
    }

    $parts = @($ApplicationVersion.Split('.') | ForEach-Object { [int]$_ })
    if (-not $StorePackageVersion) {
        $StorePackageVersion = "1.$($parts[1]).$($parts[2]).0"
    }
    $notes = @"
(Burke's agent reporting)

Source archive for MirrorMe $ApplicationVersion, target commit $SourceCommit. The reported Store package version is $StorePackageVersion.

The Store build of MirrorMe.exe is made from this commit after this release; a byte-for-byte rebuild match is not verified. The release includes the source archive, manifest, and SHA-256 checksums.
"@
    [IO.File]::WriteAllText($notesPath, $notes, [Text.UTF8Encoding]::new($false))
    Invoke-Checked 'gh' @(
        'release', 'create', $tag, $archivePath, $manifestPath, $checksumsPath,
        '--repo', $Repository,
        '--title', "MirrorMe $ApplicationVersion source release",
        '--notes-file', $notesPath,
        '--prerelease'
    )
    & (Join-Path $PSScriptRoot 'verify-source-release.ps1') `
        -ApplicationVersion $ApplicationVersion -ExpectedCommit $SourceCommit -Repository $Repository
} finally {
    Pop-Location
}
