#Requires -Version 7.2
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuilds the pinned OpenSSL and libplist packages from their retained MSYS2
# recipes, then runs the native tests against the result. The application keeps
# linking the pinned packages; this only proves the retained sources still build.
[CmdletBinding()]
param(
    [string]$MsysRoot = '',
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin',
    [ValidateRange(1, 64)][int]$Jobs = [Math]::Min(8, [Environment]::ProcessorCount)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
if (-not $MsysRoot) { $MsysRoot = Join-Path $root 'build\toolchain\msys64' }
$work = Join-Path $root 'build\ndr'
$sdk = Join-Path $work 'sdk\ucrt64'
$receiptPath = Join-Path $root 'native\dependency-rebuild-receipt.json'
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
    foreach ($directory in @($work)) {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
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
            Copy-Item -LiteralPath $source -Destination $recipe
        }
        $unixRecipe = (& $bash -lc "cygpath -u '$recipe'").Trim()
        if ($LASTEXITCODE -ne 0 -or -not $unixRecipe) { throw 'Could not convert the recipe path.' }
        $log = Join-Path $work "$($package.name).log"
        # --skippgpcheck: makepkg still verifies each source against the PKGBUILD's SHA-256.
        Invoke-Msys "cd '$unixRecipe' && makepkg-mingw --syncdeps --noconfirm --cleanbuild --force --nocheck --skippgpcheck" $log
        $built = @(Get-ChildItem -LiteralPath $recipe -Filter 'mingw-w64-ucrt-x86_64-*.pkg.tar.zst' -File |
            Where-Object { $_.Name -notmatch '-debug-' })
        if ($built.Count -ne 1) { throw "Expected one rebuilt package for $($package.name)." }
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

    $env:PATH = "$ToolchainDirectory;$oldPath"
    $gcc = Join-Path $ToolchainDirectory 'gcc.exe'
    $gxx = Join-Path $ToolchainDirectory 'g++.exe'
    $audio = Join-Path $root 'build\native-audio\install'
    $binary = Join-Path $work 'cmake'
    Invoke-Checked 'cmake' @('-S', (Join-Path $root 'native'), '-B', $binary, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_C_COMPILER=$gcc", "-DCMAKE_CXX_COMPILER=$gxx",
        '-DMM_PROTOCOL_ONLY=OFF', "-DNATIVE_SDK_DIR=$sdk", "-DAUDIO_SDK_DIR=$audio")
    Invoke-Checked 'cmake' @('--build', $binary, '--parallel', "$Jobs")
    $ctestLog = Join-Path $work 'ctest.log'
    & ctest --test-dir $binary --output-on-failure *> $ctestLog
    $ctestExit = $LASTEXITCODE
    $ctestLines = @(Get-Content -LiteralPath $ctestLog)
    if ($ctestExit -ne 0) {
        $ctestLines | Select-Object -Last 60 | Write-Host
        throw "Native tests failed against the rebuilt libraries (exit code $ctestExit)."
    }
    $summary = @($ctestLines | Where-Object { $_ -match 'tests passed' }) | Select-Object -Last 1
    $suites = @($ctestLines | ForEach-Object {
        $match = [regex]::Match($_, 'Test\s+#\d+:\s+(\S+)\s+\.+\s+Passed')
        if ($match.Success) { $match.Groups[1].Value }
    })

    $receipt = [ordered]@{
        schemaVersion = 1
        scope = 'Verification rebuild from the retained MSYS2 recipes. The application still links the pinned package archives, not these outputs.'
        executedOnUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        recipesExecuted = $true
        upstreamCheckPhaseRun = $false
        rebuildEnvironment = @($environmentLines)
        hostArchitecture = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        packages = @($results.ToArray())
        nativeTestsAgainstRebuiltLibraries = [ordered]@{
            compilerVersion = (& $gcc -dumpfullversion).Trim()
            passed = $true
            suites = @($suites)
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
} finally {
    $env:PATH = $oldPath
    foreach ($name in $oldEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name])
    }
}
