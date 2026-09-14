#Requires -Version 7.2
# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$output = Join-Path $repo 'build\native-sources'
$downloads = Join-Path $output 'downloads'
$staging = Join-Path $output 'staging'
$work = Join-Path $output 'work'
$bundle = Join-Path $output 'bundle'
$pinPath = Join-Path $repo 'native\source-dependencies.json'
$pins = Get-Content $pinPath -Raw | ConvertFrom-Json
$nativePins = Get-Content (Join-Path $repo 'native\dependencies.json') -Raw | ConvertFrom-Json
$audioPins = Get-Content (Join-Path $repo 'native\audio-dependencies.json') -Raw | ConvertFrom-Json
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
$git = (Get-Command git.exe -ErrorAction Stop).Source
$gcc = Join-Path $ToolchainDirectory 'gcc.exe'
$observations = [Collections.Generic.List[object]]::new()

function Assert-Exit([string]$operation) {
    if ($LASTEXITCODE -ne 0) { throw "$operation failed ($LASTEXITCODE)." }
}
function Hash([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Hash([string]$path, [string]$expected) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing input: $path" }
    $actual = Hash $path
    if ($actual -ne $expected) { throw "SHA-256 mismatch: $path; expected $expected, got $actual" }
}
function Ensure-Directory([string]$path) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
function Copy-Verified([string]$source, [string]$destination) {
    $before = Hash $source
    Ensure-Directory (Split-Path $destination -Parent)
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Assert-Hash $destination $before
    Assert-Hash $source $before
}
function Get-Pinned([string]$file, [string]$url, [string]$expected) {
    # Existing archives are verified in place. Nothing in another build directory
    # is edited, replaced or rebuilt, including shared native static archives.
    $candidates = @(
        (Join-Path $downloads $file),
        (Join-Path $output "discovery\$file"),
        (Join-Path $repo "build\native\downloads\$file"),
        (Join-Path $repo "build\native-audio\$file")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Assert-Hash $candidate $expected
            return $candidate
        }
    }
    if ($Offline) { throw "Offline input unavailable: $file ($url)" }
    $destination = Join-Path $downloads $file
    $partial = "$destination.partial"
    try {
        Invoke-WebRequest -Uri $url -OutFile $partial
        Assert-Hash $partial $expected
        Move-Item -LiteralPath $partial -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
    return $destination
}
function Extract-Selected([string]$archive, [string]$directory, [string[]]$members, [int]$strip = 0) {
    Ensure-Directory $directory
    $arguments = @('-xf', $archive, '-C', $directory)
    if ($strip) { $arguments += "--strip-components=$strip" }
    & $tar @arguments @members
    Assert-Exit "Extracting verified archive members from $archive"
}
function Snapshot-Tree([string]$source, [string]$destination) {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Missing source tree: $source" }
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File -Force) {
        $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
        if ($relative -match '(^|[\\/])(?:\.git|__pycache__)([\\/]|$)') { continue }
        if ($file.Extension -in @('.a', '.o', '.obj', '.exe', '.dll', '.pyc')) { continue }
        Copy-Verified $file.FullName (Join-Path $destination $relative)
    }
}

Ensure-Directory $output
Ensure-Directory $downloads
foreach ($directory in @($staging, $work)) {
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    Ensure-Directory $directory
}
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
try {
    $env:TEMP = $work
    $env:TMP = $work
    $runtime = $pins.compilerRuntime
    $version = (& $gcc -dumpfullversion).Trim()
    Assert-Exit 'Compiler version identification'
    $target = (& $gcc -dumpmachine).Trim()
    Assert-Exit 'Compiler target identification'
    if ($version -ne $runtime.compilerVersion -or $target -ne $runtime.target) {
        throw "Unpinned compiler: $version $target"
    }
    $nativeLinkPath = Join-Path $repo 'build\native\link-manifest.json'
    $nativeLink = Get-Content $nativeLinkPath -Raw | ConvertFrom-Json
    if (-not $nativeLink.production) { throw 'A production native link manifest is required.' }
    Assert-Hash $nativeLink.mergedArchive $nativeLink.mergedArchiveSha256
    $initialMergedHash = $nativeLink.mergedArchiveSha256

    foreach ($package in $pins.packages) {
        $buildPin = @($nativePins.packages | Where-Object { $_.name -eq $package.name })
        if ($buildPin.Count -ne 1 -or $buildPin[0].sha256 -ne $package.packageSha256 -or
            $buildPin[0].file -ne $package.packageFile) {
            throw "Native build/package source pins disagree for $($package.name)"
        }
        $binary = Get-Pinned $package.packageFile "$($pins.packageRepository)/$($package.packageFile)" $package.packageSha256
        $metadata = Join-Path $staging "packages\$($package.name)"
        Extract-Selected $binary $metadata @('.BUILDINFO', '.PKGINFO', '.MTREE')
        $info = Get-Content (Join-Path $metadata '.BUILDINFO') -Raw
        $recipeDigest = [regex]::Match($info, '(?m)^pkgbuild_sha256sum = ([a-f0-9]{64})\r?$').Groups[1].Value
        $packageVersion = [regex]::Match($info, '(?m)^pkgver = ([^\r\n]+)').Groups[1].Value
        if ($recipeDigest -ne $package.pkgbuildSha256 -or $packageVersion -ne $package.version) {
            throw "Package BUILDINFO does not match source pin: $($package.name)"
        }
        $recipeDirectory = Join-Path $staging "recipes\$($package.name)"
        foreach ($file in $package.recipeFiles) {
            $url = "https://raw.githubusercontent.com/msys2/MINGW-packages/$($package.recipeCommit)/mingw-w64-$($package.name)/$($file.name)"
            $input = Get-Pinned $file.cacheFile $url $file.sha256
            Copy-Verified $input (Join-Path $recipeDirectory $file.name)
        }
        Assert-Hash (Join-Path $recipeDirectory 'PKGBUILD') $recipeDigest
        $recipeText = Get-Content (Join-Path $recipeDirectory 'PKGBUILD') -Raw
        if (-not $recipeText.Contains($package.sourceSha256)) { throw 'Source hash is absent from verified PKGBUILD.' }
        foreach ($file in $package.recipeFiles | Where-Object { $_.name -ne 'PKGBUILD' }) {
            if (-not $recipeText.Contains($file.sha256)) { throw "Patch/addition absent from verified recipe: $($file.name)" }
        }
        $source = Get-Pinned $package.sourceFile $package.sourceUrl $package.sourceSha256
        Copy-Verified $source (Join-Path $recipeDirectory $package.sourceFile)
        Extract-Selected $source (Join-Path $staging "licenses\$($package.name)") $package.licenseMembers 1
        $binaryCheck = Join-Path $work $package.name
        Extract-Selected $binary $binaryCheck @($package.archiveMember)
        $extracted = Join-Path $binaryCheck $package.archiveMember.Replace('/', '\')
        Assert-Hash $extracted $package.archiveSha256
        $installed = Join-Path $repo "build\native\sdk\$($package.archiveMember.Replace('/', '\'))"
        Assert-Hash $installed $package.archiveSha256
        $observations.Add([ordered]@{
            component = $package.name
            packageSha256 = $package.packageSha256
            staticArchiveSha256 = $package.archiveSha256
            installedArchiveMatchesPackage = $true
            pkgbuildMatchesBuildinfo = $true
            recipeCommit = $package.recipeCommit
            sourceAndAllRecipeInputHashesVerified = $true
            historicalPackageBinaryRebuilt = $false
        })
    }

    foreach ($resource in $pins.noticeResources) {
        $input = Get-Pinned $resource.file $resource.url $resource.sha256
        Copy-Verified $input (Join-Path $staging "licenses\$($resource.file)")
    }
    foreach ($resource in $pins.additionalResources) {
        $input = Get-Pinned $resource.file $resource.url $resource.sha256
        Copy-Verified $input (Join-Path $staging $resource.destination.Replace('/', '\'))
    }

    $protocol = $pins.protocol
    if ($protocol.commit -ne $nativePins.protocol.commit) { throw 'Protocol source/build pins disagree.' }
    $vendor = Join-Path $repo 'receiver\vendor\libuxplay'
    $head = (& $git -C $vendor rev-parse HEAD).Trim()
    Assert-Exit 'Protocol commit verification'
    $dirty = & $git -C $vendor status --porcelain
    Assert-Exit 'Protocol checkout verification'
    if ($head -ne $protocol.commit -or $dirty) { throw 'Pinned protocol checkout is not pristine.' }
    $protocolArchive = Get-Pinned $protocol.sourceFile $protocol.sourceUrl $protocol.sourceSha256
    Copy-Verified $protocolArchive (Join-Path $staging "protocol\$($protocol.sourceFile)")
    $members = @($protocol.licenseMembers | ForEach-Object { "$($protocol.sourceRoot)/$_" })
    Extract-Selected $protocolArchive (Join-Path $staging 'licenses\protocol') $members 1
    Snapshot-Tree (Join-Path $repo 'build\native\protocol') (Join-Path $staging 'protocol\patched')
    $observations.Add([ordered]@{
        component = 'protocol'
        commit = $head
        sourceArchiveSha256 = $protocol.sourceSha256
        pristineCheckoutVerified = $true
        modifications = 'rebuild-inputs/native/patches/prepare-protocol.py; protocol/patched contains the current native build source'
    })

    $audio = $audioPins.ffmpeg
    $audioArchive = Get-Pinned "ffmpeg-$($audio.version).tar.xz" $audio.sourceUrl $audio.sourceSha256
    Copy-Verified $audioArchive (Join-Path $staging "audio\ffmpeg-$($audio.version).tar.xz")
    $audioBuildPath = Join-Path $repo 'build\native-audio\build-manifest.json'
    $audioBuild = Get-Content $audioBuildPath -Raw | ConvertFrom-Json
    if ($audioBuild.sourceSha256 -ne $audio.sourceSha256 -or
        $audioBuild.strictPacketPatchSha256 -ne $audio.strictPacketPatchSha256) {
        throw 'Compiled codec archive/source provenance mismatch.'
    }
    foreach ($library in @('avcodec', 'avutil')) {
        Assert-Hash (Join-Path $repo "build\native-audio\install\lib\lib$library.a") $audioBuild."${library}Sha256"
    }
    $patch = Join-Path $repo 'native\tests\audio_ffmpeg_strict.patch'
    $normalized = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($patch).Replace("`r`n", "`n"))
    $patchHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($normalized)).ToLowerInvariant()
    if ($patchHash -ne $audio.strictPacketPatchSha256) { throw 'Unpinned FFmpeg source patch.' }
    Snapshot-Tree (Join-Path $repo 'build\native-audio\install\share\licenses\ffmpeg') (Join-Path $staging 'licenses\ffmpeg')
    Copy-Verified $audioBuildPath (Join-Path $staging 'audio\build-manifest.json')
    Copy-Verified (Join-Path $repo 'build\native-audio\objects\ffbuild\config.sh') (Join-Path $staging 'audio\config.sh')
    $observations.Add([ordered]@{
        component = 'ffmpeg'
        version = $audio.version
        sourceArchiveSha256 = $audio.sourceSha256
        strictPacketPatchSha256 = $patchHash
        avcodecSha256 = $audioBuild.avcodecSha256
        avutilSha256 = $audioBuild.avutilSha256
        compiledArchiveHashesMatchSourceBuildManifest = $true
        originalSourceAndBuildInputsCollected = $true
    })
    $encoder = $audioPins.testFixtureEncoder
    $encoderArchive = Get-Pinned "libxaac-$($encoder.commit.Substring(0, 7)).tar.gz" $encoder.sourceUrl $encoder.sourceSha256
    Copy-Verified $encoderArchive (Join-Path $staging "test-only\libxaac-$($encoder.commit).tar.gz")

    $vendorRuntime = Get-Pinned $runtime.vendorFile $runtime.vendorUrl $runtime.vendorSha256
    $runtimeWork = Join-Path $work 'compiler-runtime'
    $runtimeMembers = @($runtime.archives | ForEach-Object { $_.member }) + @('mingw64/version_info.txt')
    Extract-Selected $vendorRuntime $runtimeWork $runtimeMembers
    foreach ($archive in $runtime.archives) {
        $installed = (& $gcc "-print-file-name=$($archive.name)").Trim()
        Assert-Exit "Locating compiler runtime $($archive.name)"
        Assert-Hash $installed $archive.sha256
        Assert-Hash (Join-Path $runtimeWork $archive.member.Replace('/', '\')) $archive.sha256
        $observations.Add([ordered]@{
            component = $archive.name
            sha256 = $archive.sha256
            installedArchiveMatchesPinnedVendorBundle = $true
            vendorBundleSha256 = $runtime.vendorSha256
            compilerSourceRebuilt = $false
        })
    }
    $toolchainRoot = Split-Path $ToolchainDirectory -Parent
    $versionInfo = Join-Path $toolchainRoot 'version_info.txt'
    Assert-Hash $versionInfo $runtime.installedVersionInfoSha256
    Copy-Verified $versionInfo (Join-Path $staging 'compiler-runtime\installed-version_info.txt')
    Copy-Verified (Join-Path $runtimeWork 'mingw64\version_info.txt') (Join-Path $staging 'compiler-runtime\vendor-version_info.txt')
    foreach ($entry in @(
        @('include\c++\13.2.0\thread', 'libstdcxx-thread-header.txt'),
        @('lib\gcc\x86_64-w64-mingw32\13.2.0\include\stdatomic.h', 'gcc-stdatomic-header.txt'),
        @('x86_64-w64-mingw32\include\pthread.h', 'winpthreads-header.txt')
    )) {
        Copy-Verified (Join-Path $toolchainRoot $entry[0]) (Join-Path $staging "compiler-runtime\$($entry[1])")
    }

    Snapshot-Tree (Join-Path $repo 'native') (Join-Path $staging 'rebuild-inputs\native')
    foreach ($relative in @(
        'scripts\build-native.ps1', 'scripts\build-audio-codecs.ps1', 'scripts\collect-native-sources.ps1',
        'receiver\resources\mirrorme.ico', 'receiver\tests\blue-frame.h264'
    )) {
        Copy-Verified (Join-Path $repo $relative) (Join-Path $staging "rebuild-inputs\$relative")
    }
    foreach ($relative in @(
        'build\native\link-manifest.json',
        'build\native\cmake\CMakeCache.txt',
        'build\native\cmake\build.ninja',
        'build\native\cmake\CMakeFiles\rules.ninja',
        'build\native-audio\audio-tests-imports.txt'
    )) {
        Copy-Verified (Join-Path $repo $relative) (Join-Path $staging "build-evidence\$relative")
    }
    # A collection is not evidence for an executable built after (or during) it.
    Assert-Hash $nativeLink.mergedArchive $initialMergedHash
    $currentLink = Get-Content $nativeLinkPath -Raw | ConvertFrom-Json
    if ($currentLink.mergedArchiveSha256 -ne $initialMergedHash) { throw 'Native build changed during collection; retry.' }

    $report = [ordered]@{
        schemaVersion = 1
        collectedAtUtc = [DateTime]::UtcNow.ToString('o')
        pinManifestSha256 = Hash $pinPath
        nativeMergedArchiveSha256 = $initialMergedHash
        thirdPartyLibrarySourceInputsVerified = $true
        currentNativeSourceSnapshotCaptured = $true
        finalNativeBuildSourceBindingVerified = $false
        finalApplicationDistributionApproved = $false
        observations = @($observations.ToArray())
        remainingChecks = @(
            'MSYS2 historical binaries were not byte-rebuilt; BUILDINFO records GCC 15.2/MinGW 13 environments, not the final GCC 13.2/MinGW 11 toolchain. Exact source/recipe correspondence and package archive equality are verified.',
            'Current local native source/build inputs are snapshotted. Before distributing, freeze the final application source revision, rebuild from those final inputs, and bind executable hash to its complete corresponding-source package.',
            'This native kit does not contain all Go/frontend/application dependencies or installation information. The application distributor must supply those and applicable GPL/LGPL notices/rights.',
            'Runtime exception applies to an eligible-compiled final combination. Do not distribute standalone compiler/runtime binary SDKs or rely on non-GPL-compatible GCC intermediate-code transformations without separate review.',
            'Patent/trademark/device-interoperability questions are separate; no publication or physical-device compatibility is certified.'
        )
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $staging 'collection-report.json') -Encoding utf8
    $inventory = @(Get-ChildItem -LiteralPath $staging -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = [IO.Path]::GetRelativePath($staging, $_.FullName).Replace('\', '/')
            bytes = $_.Length
            sha256 = Hash $_.FullName
        }
    })
    $inventory | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $staging 'file-inventory.json') -Encoding utf8
    foreach ($item in $inventory) {
        Assert-Hash (Join-Path $staging $item.path.Replace('/', '\')) $item.sha256
    }
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $bundle
    Write-Host "Verified native source bundle: $bundle"
    Write-Host "Collected $($inventory.Count) hash-verified files; package recipes/source and four runtime archives matched."
    Write-Host 'No shared native archive was changed or rebuilt. Final application release approval remains separate.'
} finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
