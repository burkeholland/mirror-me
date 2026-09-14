# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $root "build\native"
$manifestPath = Join-Path $build "link-manifest.json"
$manifestHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ((Get-FileHash $manifest.sourceProvenance.path -Algorithm SHA256).Hash -ne $manifest.sourceProvenance.sha256) {
    throw "Frozen source-provenance manifest hash mismatch."
}
$provenance = Get-Content $manifest.sourceProvenance.path -Raw | ConvertFrom-Json
if (-not $manifest.production -or
    (Get-FileHash $manifest.mergedArchive -Algorithm SHA256).Hash -ne $manifest.mergedArchiveSha256) {
    throw "A hash-matched frozen production archive is required."
}
foreach ($relative in @("native\receiver.cpp", "native\media.cpp", "native\include\media.h")) {
    $path = Join-Path $root $relative
    $record = @($provenance.nativeInputSnapshot | Where-Object { $_.original -eq $path })
    if ($record.Count -ne 1 -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $record[0].sha256) {
        throw "Current VIDEO source differs from the frozen production build."
    }
}
$compiler = $provenance.compiler.path
if ((Get-FileHash $compiler -Algorithm SHA256).Hash -ne $provenance.compiler.sha256) {
    throw "The recorded native compiler has changed."
}
$toolchain = Split-Path -Parent $compiler
$resource = Join-Path $build "tests\protocol_host_codec_probe-resource.o"
$program = Join-Path $build "tests\protocol_host_codec_probe.exe"
$priorPath = $env:PATH
try {
    $env:PATH = "$toolchain;$priorPath"
    & (Join-Path $toolchain "windres.exe") "-I$PSScriptRoot" "-Ocoff" `
        (Join-Path $PSScriptRoot "protocol_resource.rc") $resource
    if ($LASTEXITCODE -ne 0) { throw "Codec probe resource compilation failed." }
    $arguments = @("-std=c++17", "-O2", "-ffunction-sections", "-fdata-sections",
        "-DUNICODE", "-D_UNICODE", "-DWINVER=0x0A00", "-D_WIN32_WINNT=0x0A00",
        "-DLIBPLIST_STATIC", "-DOPENSSL_API_COMPAT=0x10101000L",
        "-I$(Join-Path $root 'native\include')", "-I$(Join-Path $build 'protocol\lib')",
        "-I$(Join-Path $manifest.staticSdk 'include')",
        (Join-Path $PSScriptRoot "protocol_host_codec_probe.cpp"), $resource,
        $manifest.mergedArchive, "-static", "-static-libgcc", "-Wl,--gc-sections")
    $arguments += @($manifest.mergedWindowsLibraries | ForEach-Object { "-l$_" })
    $arguments += @("-o", $program)
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "Frozen-archive VIDEO codec probe link failed." }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $program
    $start.WorkingDirectory = $build
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables["PATH"] = "$env:SystemRoot\System32;$env:SystemRoot"
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            throw "VIDEO codec probe exceeded its 30-second deadline."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "VIDEO codec probe failed:`n$output`n$errors" }
        Write-Host $output.TrimEnd()
    } finally { $process.Dispose() }
    if ((Get-FileHash $manifestPath -Algorithm SHA256).Hash -ne $manifestHash -or
        (Get-FileHash $manifest.mergedArchive -Algorithm SHA256).Hash -ne $manifest.mergedArchiveSha256) {
        throw "Frozen production outputs changed during verification."
    }
    Write-Host "PASS: frozen archive and manifest unchanged."
} finally { $env:PATH = $priorPath }
