# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param([string]$AudioPrefix = 'build\native-audio\install')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$compiler = 'C:\Strawberry\c\bin\g++.exe'
$windres = 'C:\Strawberry\c\bin\windres.exe'
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
Push-Location $root
try {
    New-Item -ItemType Directory -Force 'build\native-media-check' | Out-Null
    $env:TEMP = Join-Path $root 'build\native-media-check'
    $env:TMP = $env:TEMP
    $codec = Join-Path $AudioPrefix 'lib\libavcodec.a'
    $utility = Join-Path $AudioPrefix 'lib\libavutil.a'
    if (!(Test-Path $codec) -or !(Test-Path $utility)) {
        throw 'Build the real static audio decoder libraries first; this integration probe never substitutes a decoder.'
    }
    & $windres -I 'native\tests' 'native\tests\media_resource.rc' -O coff -o 'build\native-media-check\media_resource.o'
    if ($LASTEXITCODE) { throw 'Compiling the app icon failed.' }
    & $compiler -std=c++17 -O2 -Wall -Wextra -Werror -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 `
        -DMM_MEDIA_TESTING -I 'native\include' -I (Join-Path $AudioPrefix 'include') `
        'native\media.cpp' 'native\audio_decode.cpp' 'native\tests\media_audio_probe.cpp' `
        'build\native-media-check\media_resource.o' $codec $utility `
        -o 'build\native-media-check\media_audio_probe.exe' -static `
        -lmfplat -lmf -lmfuuid -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lksuser -lbcrypt -lm -latomic
    if ($LASTEXITCODE) { throw 'Compiling the production decoder/WASAPI integration probe failed.' }
    & '.\build\native-media-check\media_audio_probe.exe' 2>&1 | Tee-Object 'build\native-media-check\audio-results.txt'
    if ($LASTEXITCODE) { throw "Production audio integration failed with exit code $LASTEXITCODE." }
} finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    Pop-Location
}
