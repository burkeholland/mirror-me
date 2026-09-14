# SPDX-License-Identifier: GPL-3.0-or-later
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$tools = "C:\Strawberry\c\bin"
Push-Location $root
try {
    New-Item -ItemType Directory -Force -Path "build\native-media-check" | Out-Null
    & "$tools\windres.exe" -I native\tests native\tests\media_resource_app.rc -O coff `
        -o build\native-media-check\flicker_resource.o
    if ($LASTEXITCODE -ne 0) { throw "Flicker probe resource compilation failed." }
    & "$tools\g++.exe" -std=c++17 -O2 -Wall -Wextra -Werror -DUNICODE -D_UNICODE `
        -D_WIN32_WINNT=0x0A00 -DMM_MEDIA_TESTING native\tests\media_flicker_probe.cpp `
        native\tests\media_audio_stub.cpp build\native-media-check\flicker_resource.o `
        -o build\native-media-check\media_flicker_probe.exe -static `
        -lmfplat -lmfuuid -lole32 -loleaut32 -luuid -luser32 -lgdi32 -lksuser
    if ($LASTEXITCODE -ne 0) { throw "Flicker probe compilation failed." }
    $process = Start-Process -FilePath "$root\build\native-media-check\media_flicker_probe.exe" `
        -PassThru -NoNewWindow -RedirectStandardOutput "$root\build\native-media-check\flicker-results.txt" `
        -RedirectStandardError "$root\build\native-media-check\flicker-errors.txt"
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force
        throw "Flicker probe exceeded its deadline."
    }
    Get-Content -LiteralPath "build\native-media-check\flicker-results.txt"
    Get-Content -LiteralPath "build\native-media-check\flicker-errors.txt"
    if ($process.ExitCode -ne 0) { throw "Native display flicker regression failed." }
} finally {
    Pop-Location
}
