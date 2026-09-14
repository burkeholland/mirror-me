# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$BuildRoot,
    [string]$ToolchainBin = 'C:\Strawberry\c\bin',
    [string]$Bash = 'C:\Program Files\Git\bin\bash.exe',
    [ValidateRange(1, 64)][int]$Jobs = [Math]::Min(8, [Environment]::ProcessorCount),
    [switch]$Rebuild,
    [switch]$Test
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $BuildRoot) { $BuildRoot = Join-Path $repo 'build\native-audio' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$manifestPath = Join-Path $repo 'native\audio-dependencies.json'
$strictPatch = Join-Path $repo 'native\tests\audio_ffmpeg_strict.patch'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$dependency = $manifest.ffmpeg
$gcc = Join-Path $ToolchainBin 'gcc.exe'
$gxx = Join-Path $ToolchainBin 'g++.exe'
$make = Join-Path $ToolchainBin 'gmake.exe'
$objdump = Join-Path $ToolchainBin 'objdump.exe'
$gitRoot = Split-Path (Split-Path $Bash -Parent) -Parent
$gitUsr = Join-Path $gitRoot 'usr\bin'
$tar = Join-Path $gitUsr 'tar.exe'
$git = Join-Path $gitRoot 'cmd\git.exe'
foreach ($tool in @($Bash, $gcc, $gxx, $make, $objdump, $tar, $git)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw "Missing build tool: $tool" }
}
$version = (& $gcc -dumpfullversion).Trim()
$target = (& $gcc -dumpmachine).Trim()
if ($version -ne $manifest.toolchain.compilerVersion -or $target -ne $manifest.toolchain.target) {
    throw "Expected GCC $($manifest.toolchain.compilerVersion) $($manifest.toolchain.target); got $version $target"
}
New-Item -ItemType Directory -Force $BuildRoot | Out-Null
$scratch = Join-Path $BuildRoot 'scratch'
New-Item -ItemType Directory -Force $scratch | Out-Null
$archive = Join-Path $BuildRoot "ffmpeg-$($dependency.version).tar.xz"
$source = Join-Path $BuildRoot "ffmpeg-$($dependency.version)"
$objects = Join-Path $BuildRoot 'objects'
$prefix = Join-Path $BuildRoot 'install'
$buildManifest = Join-Path $BuildRoot 'build-manifest.json'
function Assert-Exit([string]$Description) {
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE" }
}
function Quote-Sh([string]$Text) {
    return "'" + $Text.Replace("'", "'\''") + "'"
}
function Posix-Path([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') { throw "Build tools require a local drive path: $full" }
    # cygpath can alias the scratch directory to MSYS's special temporary mount.
    # Use the explicit drive path so every intermediate stays visibly in BuildRoot.
    return '/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2).Replace('\', '/')
}
$oldPath = $env:PATH
$oldTmp = $env:TMP
$oldTemp = $env:TEMP
$oldTmpDir = $env:TMPDIR
try {
    $scratchPosix = Posix-Path $scratch
    $env:PATH = "$ToolchainBin;$gitUsr;$oldPath"
    $env:TMP = $scratch
    $env:TEMP = $scratch
    $env:TMPDIR = $scratchPosix
    if (-not (Test-Path $archive)) {
        Write-Host "Downloading official FFmpeg $($dependency.version) source..."
        Invoke-WebRequest -Uri $dependency.sourceUrl -OutFile $archive
    }
    $archiveHash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $dependency.sourceSha256) { throw 'FFmpeg source SHA-256 mismatch; refusing to extract or build.' }
    $manifestHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scriptHash = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $patchBytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($strictPatch).Replace("`r`n", "`n"))
    $patchHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($patchBytes)).ToLowerInvariant()
    if ($patchHash -ne $dependency.strictPacketPatchSha256) { throw 'FFmpeg strict-packet patch SHA-256 mismatch.' }
    $cache = if (Test-Path $buildManifest) { Get-Content $buildManifest -Raw | ConvertFrom-Json } else { $null }
    $needsBuild = $Rebuild -or -not $cache -or
        $cache.dependencyManifestSha256 -ne $manifestHash -or $cache.buildScriptSha256 -ne $scriptHash -or
        -not (Test-Path (Join-Path $prefix 'lib\libavcodec.a')) -or
        -not (Test-Path (Join-Path $prefix 'lib\libavutil.a'))
    if ($needsBuild) {
        Get-ChildItem $scratch -Filter 'ffconf*' | Remove-Item -Force -Recurse
        # Always extract authenticated source anew; no cached source edits enter release archives.
        foreach ($directory in @($source, $objects, $prefix)) {
            if (Test-Path $directory) { Remove-Item -Recurse -Force $directory }
        }
        New-Item -ItemType Directory -Force $objects | Out-Null
        & $tar -xJf (Posix-Path $archive) -C (Posix-Path $BuildRoot)
        Assert-Exit 'FFmpeg extraction'
        & $git -C $source apply --ignore-space-change --check $strictPatch
        Assert-Exit 'FFmpeg strict-packet patch check'
        & $git -C $source apply --ignore-space-change $strictPatch
        Assert-Exit 'FFmpeg strict-packet patch'
        $flags = @("--prefix=$(Posix-Path $prefix)", "--cc=$(Posix-Path $gcc)",
            "--tempprefix=$scratchPosix/ffconf") + @($dependency.configureFlags)
        $configure = "export TMPDIR=$(Quote-Sh $scratchPosix); export TMP=`"`$TMPDIR`" TEMP=`"`$TMPDIR`"; " +
            "cd $(Quote-Sh (Posix-Path $objects)) && $(Quote-Sh (Posix-Path (Join-Path $source 'configure'))) " +
            (($flags | ForEach-Object { Quote-Sh $_ }) -join ' ')
        & $Bash -c $configure
        Assert-Exit 'FFmpeg configure'
        # Configure runs in MSYS, but GNU Make is a native Windows executable.
        # Normalize only generated build files, leaving upstream source untouched.
        foreach ($relative in @('makefile', 'ffbuild\config.mak', 'ffbuild\config.sh')) {
            $generated = Join-Path $objects $relative
            $content = [IO.File]::ReadAllText($generated)
            foreach ($path in @($source, $prefix, $gcc, $scratch)) {
                $content = $content.Replace((Posix-Path $path), $path.Replace('\', '/'))
            }
            [IO.File]::WriteAllText($generated, $content, [Text.UTF8Encoding]::new($false))
        }
        $env:TMPDIR = $scratch
        $shell = (Join-Path $gitUsr 'sh.exe').Replace('\', '/')
        & $make -C $objects "-j$Jobs" "SHELL=$shell" all
        Assert-Exit 'Static FFmpeg build'
        # Native make's single long header-install command exceeds Windows' command
        # limit. Copy the two archives/headers directly, one file at a time instead.
        New-Item -ItemType Directory -Force (Join-Path $prefix 'lib\pkgconfig') | Out-Null
        foreach ($library in @('libavcodec', 'libavutil')) {
            $headers = Join-Path $prefix "include\$library"
            New-Item -ItemType Directory -Force $headers | Out-Null
            Get-ChildItem (Join-Path $source $library) -Filter '*.h' | Copy-Item -Destination $headers
            Get-ChildItem (Join-Path $objects $library) -Filter '*.h' | Copy-Item -Destination $headers
            Copy-Item (Join-Path $objects "$library\$library.a") -Destination (Join-Path $prefix 'lib')
            Copy-Item (Join-Path $objects "$library\$library.pc") -Destination (Join-Path $prefix 'lib\pkgconfig')
        }
        $licenses = Join-Path $prefix 'share\licenses\ffmpeg'
        New-Item -ItemType Directory -Force $licenses | Out-Null
        Get-ChildItem $source -Filter 'COPYING*' | Copy-Item -Destination $licenses
        Copy-Item (Join-Path $source 'LICENSE.md'), $manifestPath, $PSCommandPath, $strictPatch -Destination $licenses
        Copy-Item (Join-Path $objects 'config.h'), (Join-Path $objects 'ffbuild\config.mak') -Destination $licenses
        [ordered]@{
            version = $dependency.version
            sourceUrl = $dependency.sourceUrl
            sourceSha256 = $archiveHash
            strictPacketPatchSha256 = $patchHash
            dependencyManifestSha256 = $manifestHash
            buildScriptSha256 = $scriptHash
            compiler = "$version $target UCRT"
            configureArguments = $flags
            avcodecSha256 = (Get-FileHash (Join-Path $prefix 'lib\libavcodec.a')).Hash.ToLowerInvariant()
            avutilSha256 = (Get-FileHash (Join-Path $prefix 'lib\libavutil.a')).Hash.ToLowerInvariant()
        } | ConvertTo-Json -Depth 5 | Set-Content $buildManifest -Encoding utf8
    } else {
        Write-Host 'Verified source pin; using matching static FFmpeg build.'
        foreach ($library in @('avcodec', 'avutil')) {
            $actual = (Get-FileHash (Join-Path $prefix "lib\lib$library.a")).Hash.ToLowerInvariant()
            if ($actual -ne $cache."${library}Sha256") { throw "Cached $library archive changed; rerun with -Rebuild." }
        }
    }
    if ($Test) {
        $testExe = Join-Path $BuildRoot 'audio-tests.exe'
        & $gxx -std=c++17 -O2 -Wall -Wextra -Werror -static -static-libgcc -static-libstdc++ `
            "-I$(Join-Path $repo 'native\include')" "-I$(Join-Path $prefix 'include')" `
            (Join-Path $repo 'native\audio_decode.cpp') (Join-Path $repo 'native\tests\audio_decode_test.cpp') `
            "-L$(Join-Path $prefix 'lib')" -lavcodec -lavutil -lbcrypt -lole32 -luuid -o $testExe
        Assert-Exit 'Audio tests compilation'
        & $testExe (Join-Path $repo 'native\tests\audio_fixtures')
        Assert-Exit 'Audio decoder tests'
        $imports = & $objdump -p $testExe
        Assert-Exit 'PE import inspection'
        $dlls = @($imports | Select-String 'DLL Name:\s+(.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
        $allowed = '^(?:api-ms-win-[a-z0-9-]+|ext-ms-win-[a-z0-9-]+|kernel32|ntdll|ucrtbase|msvcrt|bcrypt|advapi32|ole32|oleaut32|uuid|user32|ws2_32|secur32|shell32)\.dll$'
        $unexpected = @($dlls | Where-Object { $_ -notmatch $allowed })
        if ($unexpected.Count) { throw "Non-Windows DLL imports: $($unexpected -join ', ')" }
        $dlls | Set-Content (Join-Path $BuildRoot 'audio-tests-imports.txt')
        Write-Host "Verified Windows-only imports: $($dlls -join ', ')"
    }
    Write-Host "Static audio prefix: $prefix"
    Write-Host 'Link: libavcodec.a libavutil.a -lbcrypt -lole32 -luuid -static -static-libgcc -static-libstdc++'
} finally {
    $env:PATH = $oldPath
    $env:TMP = $oldTmp
    $env:TEMP = $oldTemp
    $env:TMPDIR = $oldTmpDir
}
