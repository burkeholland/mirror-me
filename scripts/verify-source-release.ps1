#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ApplicationVersion,
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedCommit,
    [string]$Repository = 'burkeholland/mirror-me',
    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')]
    [string]$ExpectedCollectionReportSha256 = '',
    [switch]$LocalOnly,
    [string]$LocalArchivePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ZipEntryText([IO.Compression.ZipArchive]$Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { throw "Source archive is missing $Name." }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-ZipEntryHash([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return [Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant()
        } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-ZipEntrySha512([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try {
        $sha = [Security.Cryptography.SHA512]::Create()
        try {
            return [Convert]::ToBase64String($sha.ComputeHash($stream))
        } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
}

$tag = "v$ApplicationVersion-preview.1"
$ExpectedCommit = $ExpectedCommit.ToLowerInvariant()
$archiveName = "MirrorMe-$ApplicationVersion-source.zip"
$cleanupDownloadDirectory = $false
if ($LocalOnly) {
    if (-not $LocalArchivePath) {
        throw 'Local source release verification requires -LocalArchivePath.'
    }
    if (-not [IO.Path]::IsPathRooted($LocalArchivePath)) {
        $LocalArchivePath = Join-Path (Get-Location) $LocalArchivePath
    }
    $archivePath = [IO.Path]::GetFullPath($LocalArchivePath)
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Local source archive is missing: $archivePath"
    }
    if ([IO.Path]::GetFileName($archivePath) -cne $archiveName) {
        throw "Local source archive must be named $archiveName."
    }
    $downloadDirectory = Split-Path -Parent $archivePath
    $manifestPath = Join-Path $downloadDirectory 'release-manifest.json'
    $checksumsPath = Join-Path $downloadDirectory 'SHA256SUMS.txt'
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -or
        -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'Source release verification requires Git and GitHub CLI.'
    }
    $localCommit = (& git rev-parse "$tag^{commit}").Trim()
    if ($LASTEXITCODE -ne 0 -or $localCommit -ne $ExpectedCommit) {
        throw "Local tag $tag does not resolve to expected commit $ExpectedCommit."
    }

    $remoteLines = @(& git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")
    if ($LASTEXITCODE -ne 0) { throw "Could not verify remote tag $tag." }
    $remoteCommit = ''
    $directCommit = ''
    foreach ($line in $remoteLines) {
        $fields = $line -split "`t", 2
        if ($fields.Count -ne 2) { continue }
        if ($fields[1] -eq "refs/tags/$tag^{}") { $remoteCommit = $fields[0] }
        elseif ($fields[1] -eq "refs/tags/$tag") { $directCommit = $fields[0] }
    }
    if (-not $remoteCommit) { $remoteCommit = $directCommit }
    if (-not $remoteCommit -or $remoteCommit -ne $ExpectedCommit) {
        throw "Remote tag $tag does not resolve to expected commit $ExpectedCommit."
    }

    $releaseLines = @(& gh release view $tag --repo $Repository --json tagName,isDraft,isPrerelease,assets,body)
    if ($LASTEXITCODE -ne 0) { throw "Published source release $tag was not found." }
    $release = ($releaseLines -join "`n") | ConvertFrom-Json
    if ($release.tagName -ne $tag -or $release.isDraft -or -not $release.isPrerelease) {
        throw "GitHub release $tag is missing, a draft, or not marked as a prerelease."
    }
    if ($release.body -notmatch '(?i)MirrorMe\.exe.{0,120}(?:not verified|unverified)') {
        throw 'Release notes must disclose that the MirrorMe.exe source match is not verified.'
    }
    if ($release.body -match '(?i)\b(?:legally\s+compliant|legal\s+compliance\s+verified)\b') {
        throw 'Release notes must not claim legal compliance.'
    }

    $assetNames = @($release.assets | ForEach-Object { [string]$_.name })
    foreach ($required in @($archiveName, 'release-manifest.json', 'SHA256SUMS.txt')) {
        if ($required -notin $assetNames) { throw "Source release is missing asset $required." }
    }

    $downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) "MirrorMe-source-verify-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $downloadDirectory | Out-Null
    $manifestPath = Join-Path $downloadDirectory 'release-manifest.json'
    $checksumsPath = Join-Path $downloadDirectory 'SHA256SUMS.txt'
    $archivePath = Join-Path $downloadDirectory $archiveName
    $cleanupDownloadDirectory = $true
}
try {
    if (-not $LocalOnly) {
        Invoke-Checked 'gh' @('release', 'download', $tag, '--repo', $Repository, '--dir', $downloadDirectory)
    }
    foreach ($path in @($archivePath, $manifestPath, $checksumsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Source release package is missing $(Split-Path -Leaf $path)."
        }
    }

    $checksumEntries = @{}
    foreach ($line in Get-Content -LiteralPath $checksumsPath) {
        if ($line -notmatch '^([a-f0-9]{64})\s{2}(.+)$') {
            throw 'Release SHA256SUMS.txt contains a malformed entry.'
        }
        $checksumEntries[$Matches[2]] = $Matches[1]
    }
    foreach ($name in @($archiveName, 'release-manifest.json')) {
        if (-not $checksumEntries.ContainsKey($name)) {
            throw "Release checksums do not cover $name."
        }
        if ((Get-Hash (Join-Path $downloadDirectory $name)) -ne $checksumEntries[$name]) {
            throw "Release checksum mismatch for $name."
        }
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.version -ne $ApplicationVersion -or $manifest.tag -ne $tag -or
        $manifest.sourceCommit -ne $ExpectedCommit -or
        $manifest.storeBinaryMatchStatus -ne 'not verified' -or
        $manifest.sourceArchive.sha256 -ne (Get-Hash $archivePath)) {
        throw 'Published source release manifest does not match the requested version, tag, commit, or archive.'
    }
    if (-not $manifest.verification.sourceArchiveContentsVerified -or
        -not $manifest.verification.sourceTreeSafetyScanPassed -or
        $manifest.verification.binarySourceMatchClaimed) {
        throw 'Published source release manifest does not record the required safety checks or claims a binary match.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $sourceManifest = Get-ZipEntryText $archive 'MirrorMe-source/source-manifest.json' | ConvertFrom-Json
        if ($sourceManifest.applicationVersion -ne $ApplicationVersion -or
            $sourceManifest.sourceTag -ne $tag -or
            $sourceManifest.sourceCommit -ne $ExpectedCommit -or
            $sourceManifest.storeExecutableMatchStatus -ne 'not verified') {
            throw 'Source archive manifest does not match the published release.'
        }
        if (-not $sourceManifest.verification.nativeBundleInventoryVerified -or
            -not $sourceManifest.verification.protocolGitBundleVerified -or
            -not $sourceManifest.verification.GoModuleSourcesDownloadedAndVerified -or
            -not $sourceManifest.verification.licenseTreeGenerated -or
            -not $sourceManifest.verification.sourceSafetyScanPassed) {
            throw 'Source archive manifest does not record all required source checks.'
        }
        $requiredEntries = @(
            'MirrorMe-source/application-source.tar',
            'MirrorMe-source/protocol.git.bundle',
            'MirrorMe-source/native-sources/collection-report.json',
            'MirrorMe-source/go-modules.json',
            'MirrorMe-source/REBUILD.ps1',
            'MirrorMe-source/LICENSE',
            'MirrorMe-source/COPYING-GPL-3.0.txt',
            'MirrorMe-source/THIRD-PARTY-NOTICES.md',
            'MirrorMe-source/NATIVE-SOURCE-NOTICES.txt',
            'MirrorMe-source/sender/WinPlay-source.tar',
            'MirrorMe-source/sender/winplay.patch',
            'MirrorMe-source/sender/Program.cs',
            'MirrorMe-source/sender/dependency.json',
            'MirrorMe-source/sender/packages.json',
            'MirrorMe-source/sender/README.md',
            'MirrorMe-source/licenses/COPYING-GPL-3.0.txt',
            'MirrorMe-source/licenses/application/LICENSE',
            'MirrorMe-source/licenses/application/THIRD-PARTY-NOTICES.md',
            'MirrorMe-source/licenses/native/NATIVE-SOURCE-NOTICES.txt',
            'MirrorMe-source/licenses/native/AUDIO-NOTICES.txt',
            'MirrorMe-source/licenses/native/CC0-1.0.txt',
            'MirrorMe-source/licenses/native/gcc-COPYING3',
            'MirrorMe-source/licenses/native/mingw-DISCLAIMER',
            'MirrorMe-source/licenses/native/mingw-DISCLAIMER.PD',
            'MirrorMe-source/licenses/native/ffmpeg/audio_ffmpeg_strict.patch',
            'MirrorMe-source/licenses/native/ffmpeg/audio-dependencies.json',
            'MirrorMe-source/licenses/native/ffmpeg/build-audio-codecs.ps1',
            'MirrorMe-source/licenses/native/ffmpeg/config.h',
            'MirrorMe-source/licenses/native/ffmpeg/config.mak',
            'MirrorMe-source/licenses/sender/WinPlay-LICENSE.txt',
            'MirrorMe-source/licenses/sender/WinPlay-THIRD-PARTY-NOTICES.md',
            'MirrorMe-source/licenses/file-inventory.json',
            'MirrorMe-source/SOURCE.txt'
        )
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($required in $requiredEntries) {
            if ($required -notin $entryNames) {
                throw "Source archive is missing required content: $required"
            }
        }
        $nativePins = Get-ZipEntryText $archive 'MirrorMe-source/native-sources/rebuild-inputs/native/source-dependencies.json' |
            ConvertFrom-Json
        foreach ($resource in $nativePins.additionalResources) {
            $entryName = 'MirrorMe-source/native-sources/' + ([string]$resource.destination).Replace('\', '/')
            $entry = $archive.GetEntry($entryName)
            if (-not $entry -or (Get-ZipEntryHash $entry) -ne [string]$resource.sha256) {
                throw "Source archive is missing pinned native source input: $entryName"
            }
        }
        if ($ExpectedCollectionReportSha256) {
            $reportEntry = $archive.GetEntry('MirrorMe-source/native-sources/collection-report.json')
            if (-not $reportEntry -or
                (Get-ZipEntryHash $reportEntry) -ne $ExpectedCollectionReportSha256.ToLowerInvariant()) {
                throw 'Published native source report does not match the local native build.'
            }
        }
        $senderPackages = @($archive.Entries | Where-Object {
            $_.FullName -match '^MirrorMe-source/sender/packages/[^/]+\.nupkg$'
        })
        $senderPackageManifest = @(Get-ZipEntryText $archive 'MirrorMe-source/sender/packages.json' | ConvertFrom-Json)
        if (-not $senderPackages.Count -or
            $senderPackages.Count -ne [int]$sourceManifest.senderNuGetPackageCount -or
            $senderPackageManifest.Count -ne $senderPackages.Count) {
            throw 'Source archive NuGet package count does not match its manifest.'
        }
        $senderDependencies = Get-ZipEntryText $archive 'MirrorMe-source/sender/dependency.json' |
            ConvertFrom-Json
        if ([string]$sourceManifest.senderSourceCommit -ne [string]$senderDependencies.commit) {
            throw 'Source archive sender commit does not match its frozen dependency manifest.'
        }
        foreach ($senderInput in @(
            [pscustomobject]@{
                path = 'MirrorMe-source/sender/winplay.patch'
                hash = [string]$sourceManifest.senderPatchSha256
            },
            [pscustomobject]@{
                path = 'MirrorMe-source/sender/Program.cs'
                hash = [string]$sourceManifest.senderWrapperSha256
            }
        )) {
            $senderEntry = $archive.GetEntry($senderInput.path)
            if (-not $senderEntry -or
                (Get-ZipEntryHash $senderEntry) -ne $senderInput.hash.ToLowerInvariant()) {
                throw "Source archive sender input does not match its manifest: $($senderInput.path)"
            }
        }
        $expectedPackageEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($package in $senderPackageManifest) {
            $coordinate = [regex]::Match(
                [string]$package.package,
                '^([A-Za-z0-9._-]+)/([A-Za-z0-9.+-]+)$'
            )
            $archiveName = [string]$package.archive
            if (-not $coordinate.Success -or $archiveName -notmatch '^[A-Za-z0-9._+-]+\.nupkg$' -or
                [string]$package.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
                [string]$package.sha512 -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
                throw "Source archive NuGet inventory contains an invalid entry: $($package | ConvertTo-Json -Compress)"
            }
            $expectedArchiveName = "$($coordinate.Groups[1].Value.ToLowerInvariant()).$($coordinate.Groups[2].Value.ToLowerInvariant()).nupkg"
            if ($archiveName -cne $expectedArchiveName) {
                throw "Source archive NuGet archive name does not match its package coordinate: $($package.package)"
            }
            $entryName = "MirrorMe-source/sender/packages/$archiveName"
            $entry = $archive.GetEntry($entryName)
            if (-not $expectedPackageEntries.Add($entryName) -or -not $entry -or
                (Get-ZipEntryHash $entry) -ne [string]$package.sha256.ToLowerInvariant() -or
                (Get-ZipEntrySha512 $entry) -ne [string]$package.sha512) {
                throw "Source archive NuGet package inventory mismatch: $entryName"
            }
        }
        if ($expectedPackageEntries.Count -ne $senderPackages.Count) {
            throw 'Source archive contains unindexed NuGet package archives.'
        }
        foreach ($entry in $senderPackages) {
            if (-not $expectedPackageEntries.Contains($entry.FullName)) {
                throw "Source archive contains an unindexed NuGet package archive: $($entry.FullName)"
            }
        }
        foreach ($requiredPackageId in @('microsoft.netcore.app.runtime.win-x64')) {
            $requiredPackages = @($senderPackageManifest | Where-Object {
                ([string]$_.package).StartsWith("$requiredPackageId/", [StringComparison]::OrdinalIgnoreCase)
            })
            if ($requiredPackages.Count -ne 1) {
                throw "Source archive must include exactly one $requiredPackageId package for win-x64."
            }
        }

        $licenseInventory = Get-ZipEntryText $archive 'MirrorMe-source/licenses/file-inventory.json' |
            ConvertFrom-Json
        if (@($licenseInventory).Count -eq 0) {
            throw 'Source archive license inventory is empty.'
        }
        foreach ($item in $licenseInventory) {
            $relativePath = [string]$item.path
            if ([IO.Path]::IsPathRooted($relativePath) -or
                $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Source archive license inventory contains an unsafe path: $relativePath"
            }
            $entryName = 'MirrorMe-source/licenses/' + $relativePath.Replace('\', '/')
            $entry = $archive.GetEntry($entryName)
            if (-not $entry -or $entry.Length -ne [long]$item.bytes -or
                (Get-ZipEntryHash $entry) -ne [string]$item.sha256) {
                throw "Source archive license inventory mismatch: $entryName"
            }
        }
        $sourceText = Get-ZipEntryText $archive 'MirrorMe-source/SOURCE.txt'
        $expectedSourceText = "MirrorMe $ApplicationVersion source release:`nhttps://github.com/burkeholland/mirror-me/releases/tag/$tag`n"
        if ($sourceText.Replace("`r`n", "`n") -ne $expectedSourceText) {
            throw 'Source archive SOURCE.txt does not identify the exact source tag.'
        }
        $inventory = Get-ZipEntryText $archive 'MirrorMe-source/file-inventory.json' | ConvertFrom-Json
        foreach ($item in $inventory) {
            $entryName = 'MirrorMe-source/' + ([string]$item.path).Replace('\', '/')
            $entry = $archive.GetEntry($entryName)
            if (-not $entry) { throw "Source archive inventory entry is missing: $entryName" }
            if ((Get-ZipEntryHash $entry) -ne [string]$item.sha256 -or $entry.Length -ne [long]$item.bytes) {
                throw "Source archive inventory mismatch: $entryName"
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    if ($cleanupDownloadDirectory) {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force
    }
}

Write-Host "Verified source-first release: $tag ($ExpectedCommit)"
