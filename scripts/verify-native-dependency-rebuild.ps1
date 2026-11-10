#Requires -Version 7.2
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuilds the pinned OpenSSL and libplist packages from their retained MSYS2
# recipes, then runs the native tests against the result. The application keeps
# linking the pinned packages; this only proves the retained sources still build.
[CmdletBinding()]
param(
    [string]$MsysRoot = '',
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin',
    [ValidateRange(1, 64)][int]$Jobs = [Math]::Min(8, [Environment]::ProcessorCount),
    [string]$ReceiptPath = '',
    # Reruns only the tests against packages an earlier run already built.
    [switch]$ReusePackages
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
if (-not $MsysRoot) { $MsysRoot = Join-Path $root 'build\toolchain\msys64' }
$work = Join-Path $root 'build\ndr'
$sdk = Join-Path $work 'sdk\ucrt64'
if (-not $ReceiptPath) { $ReceiptPath = Join-Path $root 'native\dependency-rebuild-receipt.json' }
$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'
$lock = Get-Content -LiteralPath (Join-Path $root 'native\dependencies.json') -Raw | ConvertFrom-Json
$pins = Get-Content -LiteralPath (Join-Path $root 'native\source-dependencies.json') -Raw | ConvertFrom-Json

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}
function Invoke-Msys([string]$Command, [string]$LogPath) {
    & $bash -lc $Command *> $LogPath
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $LogPath -Tail 60 | Write-Host
        throw "MSYS2 command failed with exit code $LASTEXITCODE. See $LogPath."
    }
}

if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    throw "MSYS2 was not found at $MsysRoot. Install it, or pass -MsysRoot."
}
$oldEnvironment = @{}
$msysEnvironment = @{
    MSYSTEM = 'UCRT64'
    CHERE_INVOKING = '1'
    MSYS2_PATH_TYPE = 'strict'
    MINGW_ARCH = 'ucrt64'
    MAKEFLAGS = "-j$Jobs"
}
foreach ($name in $msysEnvironment.Keys) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $msysEnvironment[$name])
}
$oldPath = $env:PATH
try {
    if (-not $ReusePackages -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
    foreach ($generated in @((Join-Path $work 'sdk'), (Join-Path $work 'cmake'), (Join-Path $work 'lib'), (Join-Path $work 'tests'))) {
        if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $sdk | Out-Null

    $results = [Collections.Generic.List[object]]::new()
    foreach ($package in $lock.packages) {
        $pin = @($pins.packages | Where-Object { $_.name -eq $package.name })
        if ($pin.Count -ne 1 -or $pin[0].packageSha256 -ne $package.sha256) {
            throw "Native build and source pins disagree for $($package.name)."
        }
        $recipe = Join-Path $work $package.name
        New-Item -ItemType Directory -Force -Path $recipe | Out-Null
        $retained = Join-Path $root "build\native\sources\$($package.name)"
        foreach ($inputFile in $package.sourceInputs) {
            $source = Join-Path $retained $inputFile.file
            if ((Get-Hash $source) -ne $inputFile.sha256) {
                throw "Retained recipe input does not match its pin: $($inputFile.file)"
            }
            if (-not $ReusePackages) { Copy-Item -LiteralPath $source -Destination $recipe }
        }
        if (-not $ReusePackages) {
            $unixRecipe = (& $bash -lc "cygpath -u '$recipe'").Trim()
            if ($LASTEXITCODE -ne 0 -or -not $unixRecipe) { throw 'Could not convert the recipe path.' }
            $log = Join-Path $work "$($package.name).log"
            # --skippgpcheck: makepkg still verifies each source against the PKGBUILD's SHA-256.
            Invoke-Msys "cd '$unixRecipe' && makepkg-mingw --syncdeps --noconfirm --cleanbuild --force --nocheck --skippgpcheck" $log
        }
        $built = @(Get-ChildItem -LiteralPath $recipe -Filter 'mingw-w64-ucrt-x86_64-*.pkg.tar.zst' -File |
            Where-Object { $_.Name -notmatch '-debug-' })
        if ($built.Count -ne 1) { throw "Expected one rebuilt package for $($package.name)." }
        # A reused package must have come from this exact pinned recipe.
        $builtInfo = (@(& tar -xOf $built[0].FullName .BUILDINFO) -join "`n")
        if ($LASTEXITCODE -ne 0) { throw "Could not read .BUILDINFO from $($built[0].Name)." }
        $builtRecipe = [regex]::Match($builtInfo, '(?m)^pkgbuild_sha256sum = ([a-f0-9]{64})\s*$').Groups[1].Value
        $builtVersion = [regex]::Match($builtInfo, '(?m)^pkgver = (\S+)\s*$').Groups[1].Value
        if ($builtRecipe -ne $pin[0].pkgbuildSha256 -or $builtVersion -ne $pin[0].version) {
            throw "$($built[0].Name) was not built from the pinned $($package.name) recipe. Rerun without -ReusePackages."
        }
        $archiveMember = [string]$pin[0].archiveMember
        $entries = @(& tar -tf $built[0].FullName)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the rebuilt package.' }
        $selected = @($entries | Where-Object {
            $_ -eq $archiveMember -or $_ -match '^ucrt64/include/(openssl|plist)/.+[^/]$'
        })
        if ($selected.Count -lt 2 -or $archiveMember -notin $selected) {
            throw "Rebuilt package is missing $archiveMember or its headers."
        }
        Invoke-Checked 'tar' (@('-xf', $built[0].FullName, '-C', (Join-Path $work 'sdk')) + $selected)
        $rebuiltArchive = Join-Path $work "sdk\$($archiveMember.Replace('/', '\'))"
        $rebuiltHash = Get-Hash $rebuiltArchive
        $results.Add([ordered]@{
            name = [string]$package.name
            version = [string]$pin[0].version
            pinnedPackageSha256 = [string]$package.sha256
            pkgbuildSha256 = [string]$pin[0].pkgbuildSha256
            upstreamSourceSha256 = [string]$pin[0].sourceSha256
            archiveMember = $archiveMember
            pinnedArchiveSha256 = [string]$pin[0].archiveSha256
            rebuiltArchiveSha256 = $rebuiltHash
            byteIdenticalToPinned = ($rebuiltHash -eq $pin[0].archiveSha256)
        })
    }

    $environmentLog = Join-Path $work 'environment.log'
    Invoke-Msys 'gcc --version | head -1; pacman -Q mingw-w64-ucrt-x86_64-crt' $environmentLog
    $environmentLines = @(Get-Content -LiteralPath $environmentLog | Where-Object { $_.Trim() })

    # Current MSYS2 libraries need a newer CRT than the app toolchain, so the tests build
    # with the same MSYS2 compiler. CMake and Ninja still come from the app toolchain.
    $msysBin = Join-Path $MsysRoot 'ucrt64\bin'
    $env:PATH = "$msysBin;$ToolchainDirectory;$oldPath"
    $gcc = Join-Path $msysBin 'gcc.exe'
    $gxx = Join-Path $msysBin 'g++.exe'
    $audio = Join-Path $root 'build\native-audio\install'
    $binary = Join-Path $work 'cmake'
    Invoke-Checked 'cmake' @('-S', (Join-Path $root 'native'), '-B', $binary, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_C_COMPILER=$gcc", "-DCMAKE_CXX_COMPILER=$gxx",
        '-DMM_PROTOCOL_ONLY=OFF', "-DNATIVE_SDK_DIR=$sdk", "-DAUDIO_SDK_DIR=$audio")
    Invoke-Checked 'cmake' @('--build', $binary, '--parallel', "$Jobs")
    $ctestLog = Join-Path $work 'ctest.log'
    & ctest --test-dir $binary --output-on-failure *> $ctestLog
    $testExitCode = $LASTEXITCODE
    $ctestLines = @(Get-Content -LiteralPath $ctestLog)
    $outcomes = @($ctestLines | ForEach-Object {
        $match = [regex]::Match($_, 'Test\s+#\d+:\s+(\S+)\s+\.+\s*(Passed|\S.*)$')
        if ($match.Success) {
            [pscustomobject]@{ name = $match.Groups[1].Value; passed = $match.Groups[2].Value -like 'Passed*' }
        }
    })
    if (-not $outcomes.Count) {
        $ctestLines | Select-Object -Last 40 | Write-Host
        throw 'The native tests did not run against the rebuilt libraries.'
    }
    $suites = @($outcomes | Where-Object passed | ForEach-Object name)
    $failedSuites = @($outcomes | Where-Object { -not $_.passed } | ForEach-Object name)
    $summary = @($ctestLines | Where-Object { $_ -match 'tests passed' }) | Select-Object -Last 1

    $receipt = [ordered]@{
        schemaVersion = 1
        scope = 'Verification rebuild from the retained MSYS2 recipes. The application still links the pinned package archives, not these outputs.'
        executedOnUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        recipesExecuted = $true
        upstreamCheckPhaseRun = $false
        rebuildEnvironment = @($environmentLines)
        hostArchitecture = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        sourceCommit = (& git -C $root rev-parse HEAD).Trim()
        protocolPatchSha256 = (Get-Hash (Join-Path $root 'native\patches\prepare-protocol.py'))
        runUrl = $(if ($env:GITHUB_ACTIONS -eq 'true') { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { '' })
        packages = @($results.ToArray())
        nativeTestsAgainstRebuiltLibraries = [ordered]@{
            compilerVersion = (& $gcc -dumpfullversion).Trim()
            passed = @($suites)
            failed = @($failedSuites)
            summary = ([string]$summary).Trim()
        }
    }
    $json = ConvertTo-Json -InputObject $receipt -Depth 6
    [IO.File]::WriteAllText($receiptPath, $json + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Verification rebuild receipt: $receiptPath"
    foreach ($result in $results) {
        Write-Host "$($result.name) $($result.version): rebuilt $($result.archiveMember), byte-identical to pinned: $($result.byteIdenticalToPinned)"
    }
    Write-Host ([string]$summary).Trim()
    $requiredTests = @('protocol_receive_bounds', 'protocol_media_invariants', 'media_flicker', 'protocol_lifecycle')
    if ($testExitCode -ne 0 -or $failedSuites.Count -or @($requiredTests | Where-Object { $_ -notin $suites }).Count) {
        throw 'Not every native test passed against the rebuilt libraries; the receipt records failures and cannot approve a Store build.'
    }
} finally {
    $env:PATH = $oldPath
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name])
    }
}
