# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$ToolchainDirectory = "",
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",
    [ValidateRange(1, 32)]
    [int]$Parallel = 4,
    [switch]$SkipSelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$receiver = Join-Path $root "receiver"
$build = Join-Path $root "build\receiver"
$downloads = Join-Path $build "downloads"
$sdk = Join-Path $build "sdk"
$vendor = Join-Path $receiver "vendor\libuxplay"
$source = Join-Path $build "libuxplay"
$native = Join-Path $build "native"
$patch = Join-Path $receiver "patches\windows-receiver.patch"
$videoPatch = Join-Path $receiver "patches\video-lifecycle.patch"
$engine = Join-Path $root "engine"
$executable = Join-Path $engine "mirrorme-receiver.exe"
$lockPath = Join-Path $receiver "dependencies.json"
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json

function Invoke-Native {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

function Get-VerifiedFile {
    param([string]$Url, [string]$Destination, [string]$Sha256)
    if ($Sha256 -notmatch "^[0-9a-f]{64}$") {
        throw "Dependency has no valid SHA-256 pin: $Url"
    }
    if (-not (Test-Path -LiteralPath $Destination)) {
        $partial = "$Destination.part"
        try {
            Write-Host "Downloading $Url"
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) {
                throw "Downloaded dependency failed its SHA-256 check: $Url"
            }
            Move-Item -LiteralPath $partial -Destination $Destination
        } finally {
            if (Test-Path -LiteralPath $partial) {
                Remove-Item -LiteralPath $partial -Force
            }
        }
    }
    if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Cached dependency is corrupt: $Destination. Remove that file and retry."
    }
}

function Invoke-ReceiverProbe {
    param([string]$Arguments, [int]$ExpectedExit = 0, [string]$ExpectedText = "", [string]$PluginDirectory = "")
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = $Arguments
    $start.WorkingDirectory = $engine
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Do not let the development SDK or another GStreamer installation mask
    # missing runtime dependencies in the application bundle.
    $start.EnvironmentVariables["PATH"] = "$engine;$env:SystemRoot\System32;$env:SystemRoot"
    if ($PluginDirectory) {
        $start.EnvironmentVariables["GST_PLUGIN_PATH"] = $PluginDirectory
        $start.EnvironmentVariables["GST_REGISTRY"] = Join-Path $build "self-test-missing-plugin-registry.bin"
    } else {
        $start.EnvironmentVariables["GST_PLUGIN_PATH"] = Join-Path $engine "lib\gstreamer-1.0"
        $start.EnvironmentVariables["GST_REGISTRY"] = Join-Path $build "self-test-registry.bin"
    }
    $start.EnvironmentVariables["GST_REGISTRY_FORK"] = "no"
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw "Could not launch receiver probe: $Arguments"
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Receiver probe timed out: $Arguments"
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne $ExpectedExit -or
            ($ExpectedText -and $output -notmatch [regex]::Escape($ExpectedText)) -or
            $output -match "(?m)^MIRRORME_RECEIVER_READY") {
            throw "Receiver probe failed ($Arguments, status $($process.ExitCode)):`n$output`n$errors"
        }
        if ($ExpectedExit -ne 0 -and [string]::IsNullOrWhiteSpace($errors)) {
            throw "Receiver failure did not report an error on stderr: $Arguments"
        }
        Write-Host "Passed offline probe (exit $ExpectedExit): $Arguments"
    } finally {
        $process.Dispose()
    }
}

$git = (Get-Command git.exe -ErrorAction Stop).Source
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
$cmake = (Get-Command cmake.exe -ErrorAction Stop).Source
$ninja = (Get-Command ninja.exe -ErrorAction Stop).Source
if (-not $ToolchainDirectory) {
    $gccCommand = Get-Command gcc.exe -ErrorAction SilentlyContinue
    if ($gccCommand) {
        $ToolchainDirectory = Split-Path -Parent $gccCommand.Source
    } elseif (Test-Path -LiteralPath "C:\msys64\ucrt64\bin\gcc.exe") {
        $ToolchainDirectory = "C:\msys64\ucrt64\bin"
    } elseif (Test-Path -LiteralPath "C:\Strawberry\c\bin\gcc.exe") {
        $ToolchainDirectory = "C:\Strawberry\c\bin"
    } else {
        throw "Install a 64-bit MinGW-w64 UCRT toolchain and pass -ToolchainDirectory. No system packages are installed by this script."
    }
}
$gcc = Join-Path $ToolchainDirectory "gcc.exe"
$gxx = Join-Path $ToolchainDirectory "g++.exe"
$objdump = Join-Path $ToolchainDirectory "objdump.exe"
foreach ($tool in @($gcc, $gxx, $objdump)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Missing build tool: $tool" }
}
$compilerProcess = New-Object System.Diagnostics.Process
$compilerProcess.StartInfo.FileName = $gcc
$compilerProcess.StartInfo.Arguments = "-v"
$compilerProcess.StartInfo.UseShellExecute = $false
$compilerProcess.StartInfo.CreateNoWindow = $true
$compilerProcess.StartInfo.RedirectStandardOutput = $true
$compilerProcess.StartInfo.RedirectStandardError = $true
try {
    # GCC prints successful -v output to stderr. Capture it directly, rather
    # than treating it as a NativeCommandError in Windows PowerShell 5.1.
    if (-not $compilerProcess.Start()) { throw "Could not inspect $gcc" }
    $compilerStdout = $compilerProcess.StandardOutput.ReadToEndAsync()
    $compilerStderr = $compilerProcess.StandardError.ReadToEndAsync()
    if (-not $compilerProcess.WaitForExit(10000)) {
        $compilerProcess.Kill()
        $compilerProcess.WaitForExit()
        throw "Compiler inspection timed out"
    }
    if ($compilerProcess.ExitCode -ne 0) { throw "Compiler inspection failed" }
    $compiler = $compilerStdout.GetAwaiter().GetResult() + $compilerStderr.GetAwaiter().GetResult()
} finally {
    $compilerProcess.Dispose()
}
$machine = & $gcc -dumpmachine
if ($LASTEXITCODE -ne 0 -or $compiler -notmatch "ucrt" -or $machine -ne "x86_64-w64-mingw32") {
    throw "The compiler must target x86_64 UCRT. MSVCRT and MSVC are not compatible with this bundle."
}

$originalPath = $env:PATH
try {
    $env:PATH = "$ToolchainDirectory;$originalPath"
    New-Item -ItemType Directory -Force -Path $build, $downloads, $sdk, (Join-Path $sdk "bonjour"), $engine | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $vendor ".git"))) {
        if (Test-Path -LiteralPath $vendor) {
            throw "Expected a pinned Git checkout at $vendor; refusing to overwrite existing source."
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vendor) | Out-Null
        $sourceBundle = Join-Path $receiver "libuxplay.bundle"
        if (Test-Path -LiteralPath $sourceBundle) {
            Invoke-Native $git @("clone", "--quiet", "--no-checkout", $sourceBundle, $vendor)
            Invoke-Native $git @("-C", $vendor, "-c", "core.autocrlf=false", "checkout", "--quiet", "--detach", $lock.uxplay.commit)
        } else {
            Invoke-Native $git @("init", "--quiet", $vendor)
            Invoke-Native $git @("-C", $vendor, "remote", "add", "origin", $lock.uxplay.repository)
            Invoke-Native $git @("-C", $vendor, "fetch", "--quiet", "--depth", "1", "origin", $lock.uxplay.commit)
            Invoke-Native $git @("-C", $vendor, "-c", "core.autocrlf=false", "checkout", "--quiet", "--detach", "FETCH_HEAD")
        }
    }
    $head = & $git -C $vendor rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $lock.uxplay.commit) {
        throw "libuxplay must be checked out at $($lock.uxplay.commit). Existing source was not changed."
    }
    $sourceChanges = & $git -C $vendor status --porcelain
    if ($LASTEXITCODE -ne 0 -or $sourceChanges) {
        throw "Keep vendor\libuxplay pristine; put local changes in receiver\patches\windows-receiver.patch."
    }

    if (-not (Test-Path -LiteralPath (Join-Path $engine "libgstreamer-1.0-0.dll"))) {
        $runtimeLock = Get-Content -LiteralPath (Join-Path $receiver "runtime.json") -Raw | ConvertFrom-Json
        $runtimeArchive = Join-Path $downloads "uxplay-windows-$($runtimeLock.version).zip"
        Get-VerifiedFile $runtimeLock.url $runtimeArchive $runtimeLock.sha256
        $runtimeFiles = Join-Path $build "runtime-files"
        Expand-Archive -LiteralPath $runtimeArchive -DestinationPath $runtimeFiles -Force
        robocopy $runtimeFiles $engine /E /XF uxplay-windows.exe uxplay-bluetooth-beacon.exe compile_commands.json /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Could not stage the pinned development runtime." }
    }

    foreach ($package in $lock.packages) {
        $archive = Join-Path $downloads $package.file
        Get-VerifiedFile "$($lock.packageBaseUrl)/$($package.file)" $archive $package.sha256
        Invoke-Native $tar @("-xf", $archive, "-C", $sdk)
    }
    Get-VerifiedFile $lock.bonjourHeader.url (Join-Path $sdk "bonjour\dns_sd.h") $lock.bonjourHeader.sha256

    $sourceArchive = Join-Path $build "libuxplay-source.tar"
    Invoke-Native $git @("-C", $vendor, "archive", "--format=tar", "--output=$sourceArchive", $lock.uxplay.commit)
    if (Test-Path -LiteralPath $source) {
        Remove-Item -LiteralPath $source -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    Invoke-Native $tar @("-xf", $sourceArchive, "-C", $source)
    Remove-Item -LiteralPath $sourceArchive -Force
    # An enclosing app repository must not make git apply skip these paths.
    $vendorGit = & $git -C $vendor rev-parse --absolute-git-dir
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve the pinned source repository." }
    $applyArgs = @("-C", $source, "--git-dir=$vendorGit", "--work-tree=$source", "apply")
    Invoke-Native $git ($applyArgs + @("--check", $patch))
    Invoke-Native $git ($applyArgs + @($patch))
    Invoke-Native $git ($applyArgs + @("--check", $videoPatch))
    Invoke-Native $git ($applyArgs + @($videoPatch))

    Invoke-Native $cmake @(
        "--fresh", "-S", $receiver, "-B", $native, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$Configuration",
        "-DCMAKE_C_COMPILER:FILEPATH=$gcc", "-DCMAKE_CXX_COMPILER:FILEPATH=$gxx",
        "-DCMAKE_MAKE_PROGRAM:FILEPATH=$ninja",
        "-DUXPLAY_SOURCE_DIR:PATH=$source",
        "-DRECEIVER_SDK_DIR:PATH=$(Join-Path $sdk 'ucrt64')",
        "-DRECEIVER_DNSSD_INCLUDE_DIR:PATH=$(Join-Path $sdk 'bonjour')"
    )
    Invoke-Native $cmake @("--build", $native, "--parallel", "$Parallel")

    $builtExecutable = Join-Path $native "mirrorme-receiver.exe"
    $pe = (& $objdump -p $builtExecutable | Out-String)
    if ($LASTEXITCODE -ne 0 -or $pe -notmatch "Windows CUI" -or $pe -match "DLL Name:\s+Qt") {
        throw "Receiver must be a console-subsystem executable without Qt DLL imports."
    }
    # This is the only file this script writes in the existing runtime bundle.
    Copy-Item -LiteralPath $builtExecutable -Destination $executable -Force

    if (-not $SkipSelfTest) {
        Invoke-ReceiverProbe "--version" 0 "libuxplay $($lock.uxplay.commit)"
        Invoke-ReceiverProbe "--self-test" 0 "MIRRORME_RECEIVER_SELF_TEST_OK"
        Invoke-ReceiverProbe "--media-self-test" 0 "MIRRORME_MEDIA_TEST_OK"
        Invoke-ReceiverProbe "--media-self-test-software" 0 "MIRRORME_MEDIA_TEST_OK"
        Invoke-ReceiverProbe "--media-self-test-invalid" 1
        Invoke-ReceiverProbe "-help" 0 "-nh"
        $unicodeName = "MirrorMe $([char]0x00e9)$([char]0x6f22)$([char]::ConvertFromUtf32(0x1f4f1))"
        Invoke-ReceiverProbe "-n `"$unicodeName`" -help" 0 "-nh"
        Invoke-ReceiverProbe "--mirrorme-invalid-option" 1
        Invoke-ReceiverProbe "-rc mirrorme-nonexistent-self-test-config" 1
        $emptyPlugins = Join-Path $build "empty-plugins"
        New-Item -ItemType Directory -Force -Path $emptyPlugins | Out-Null
        Invoke-ReceiverProbe "--self-test" 1 "" $emptyPlugins
    }
    $binaryHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        receiverVersion = "1.0.0"
        uxplayCommit = $lock.uxplay.commit
        configuration = $Configuration
        compiler = $compiler.Trim()
        dependencyManifestSha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        patchSha256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        videoPatchSha256 = (Get-FileHash -LiteralPath $videoPatch -Algorithm SHA256).Hash.ToLowerInvariant()
        executableSha256 = $binaryHash
        offlineChecksPassed = (-not $SkipSelfTest)
        builtAtUtc = [DateTime]::UtcNow.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $build "build-manifest.json") -Encoding UTF8
    Write-Host "Built $executable"
    Write-Host "SHA256 $binaryHash"
    Write-Host "Existing engine DLLs were not replaced. No live receiver or Bonjour service was started."
} finally {
    $env:PATH = $originalPath
}
