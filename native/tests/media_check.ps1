# SPDX-License-Identifier: GPL-3.0-or-later
# Test-only FFmpeg creates synthetic fixtures; production uses Windows libraries only.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$compiler = 'C:\Strawberry\c\bin\g++.exe'
$windres = 'C:\Strawberry\c\bin\windres.exe'
if (!(Test-Path $compiler) -or !(Test-Path $windres)) {
    throw 'The native probe requires the existing Strawberry MinGW compiler and windres.'
}
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
Push-Location $root
try {
    New-Item -ItemType Directory -Force 'build\native-media-check' | Out-Null
    $env:TEMP = Join-Path $root 'build\native-media-check'
    $env:TMP = $env:TEMP
    & $ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=480x320:r=30 `
        -frames:v 1 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p `
        -f h264 -y 'build\native-media-check\landscape.h264'
    if ($LASTEXITCODE) { throw 'Synthetic landscape fixture generation failed.' }
    foreach ($orientation in @(@('3840x2160', 'landscape'), @('2160x3840', 'portrait'))) {
        $size = $orientation[0]
        $name = $orientation[1]
        & $ffmpeg -hide_banner -loglevel error -filter_threads 1 -f lavfi `
            -i "color=c=blue:s=${size}:r=30,colorspace=iall=bt601-6-625:all=bt709" `
            -frames:v 1 -c:v libx264 -threads 2 -preset ultrafast -tune zerolatency -pix_fmt yuv420p `
            -color_primaries bt709 -color_trc bt709 -colorspace bt709 -f h264 -y `
            "build\native-media-check\${name}-4k.h264"
        if ($LASTEXITCODE) { throw "Synthetic 4K $name fixture generation failed." }
    }
    & $ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=1080x1920:r=60 `
        -frames:v 40 -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p `
        -x264-params 'keyint=30:aud=1:repeat-headers=1' -f h264 -y 'build\native-media-check\inter-frames.h264'
    if ($LASTEXITCODE) { throw 'Synthetic inter-frame fixture generation failed.' }
    & $ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=480x320:r=30 `
        -frames:v 1 -c:v libx265 -preset ultrafast -pix_fmt yuv420p `
        -x265-params 'log-level=error:pools=1' -f hevc -y 'build\native-media-check\hevc.h265'
    if ($LASTEXITCODE) { throw 'Synthetic optional HEVC fixture generation failed.' }
    & $ffmpeg -hide_banner -loglevel error -i 'receiver\tests\blue-frame.h264' `
        -frames:v 1 -pix_fmt rgb24 -f rawvideo -y 'build\native-media-check\reference.rgb'
    if ($LASTEXITCODE) { throw 'Independent original-fixture pixel decoding failed.' }
    & $windres -I 'native\tests' 'native\tests\media_resource.rc' -O coff -o 'build\native-media-check\media_resource.o'
    if ($LASTEXITCODE) { throw 'Compiling the real MirrorMe icon resource failed.' }
    & $compiler -std=c++17 -O2 -Wall -Wextra -Werror -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 `
        -DMM_MEDIA_TESTING 'native\media.cpp' 'native\tests\media_audio_stub.cpp' `
        'native\tests\media_probe.cpp' 'build\native-media-check\media_resource.o' `
        -o 'build\native-media-check\media_probe.exe' -static `
        -lmfplat -lmf -lmfuuid -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lksuser
    if ($LASTEXITCODE) { throw 'Compiling the native media probe failed.' }
    & '.\build\native-media-check\media_probe.exe' 2>&1 | Tee-Object 'build\native-media-check\probe-results.txt'
    if ($LASTEXITCODE) { throw "Native media probe failed with exit code $LASTEXITCODE." }
    & $windres -I 'native\tests' 'native\tests\media_resource_app.rc' -O coff -o 'build\native-media-check\media_app_resource.o'
    if ($LASTEXITCODE) { throw 'Compiling the Wails-style ID1 app icon failed.' }
    & $compiler -std=c++17 -O2 -Wall -Wextra -Werror -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 `
        -DMM_MEDIA_TESTING 'native\media.cpp' 'native\tests\media_audio_stub.cpp' `
        'native\tests\media_probe.cpp' 'build\native-media-check\media_app_resource.o' `
        -o 'build\native-media-check\media_app_icon_probe.exe' -static `
        -lmfplat -lmf -lmfuuid -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lksuser
    if ($LASTEXITCODE) { throw 'Compiling the Wails-style app icon probe failed.' }
    & '.\build\native-media-check\media_app_icon_probe.exe' --icon-only 2>&1 | Tee-Object 'build\native-media-check\app-icon-results.txt'
    if ($LASTEXITCODE) { throw "Wails-style app icon probe failed with exit code $LASTEXITCODE." }
} finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    Pop-Location
}
