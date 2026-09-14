# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$ToolchainDirectory = "C:\Strawberry\c\bin",
    [ValidateSet("Release", "Debug")][string]$Configuration = "Release",
    [ValidateRange(1, 32)][int]$Parallel = 4,
    [string]$AudioSdkDirectory = "",
    [switch]$ProtocolOnly,
    [switch]$SkipTests,
    [switch]$ForDistribution
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$native = Join-Path $root "native"
$build = Join-Path $root "build\native"
$vendor = Join-Path $root "receiver\vendor\libuxplay"
$source = Join-Path $build "protocol"
$sdk = Join-Path $build "sdk"
$lock = Get-Content (Join-Path $native "dependencies.json") -Raw | ConvertFrom-Json
if (-not $AudioSdkDirectory) { $AudioSdkDirectory = Join-Path $root "build\native-audio\install" }

function Invoke-Tool([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "$program exited with code $LASTEXITCODE" }
}
function Invoke-MergedProbe([string]$program, [string]$directory) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $program
    $start.WorkingDirectory = $directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables["PATH"] = "$env:SystemRoot\System32;$env:SystemRoot"
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start merged native probe." }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(90000)) {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            throw "Merged native probe exceeded its 90-second deadline."
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errors = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Merged native probe failed:`n$output`n$errors" }
        Write-Host $output.TrimEnd()
    } finally { $process.Dispose() }
}
function Verified-Archive($package) {
    $cached = Join-Path $root "build\receiver\downloads\$($package.file)"
    $destination = Join-Path $build "downloads\$($package.file)"
    if (Test-Path -LiteralPath $cached) { $destination = $cached }
    if (-not (Test-Path -LiteralPath $destination)) {
        Invoke-WebRequest -UseBasicParsing -Uri "$($lock.packageBaseUrl)/$($package.file)" -OutFile "$destination.part"
        if ((Get-FileHash "$destination.part" -Algorithm SHA256).Hash -ne $package.sha256) {
            Remove-Item "$destination.part" -Force
            throw "Dependency SHA-256 mismatch."
        }
        Move-Item "$destination.part" $destination
    }
    if ((Get-FileHash $destination -Algorithm SHA256).Hash -ne $package.sha256) {
        throw "Cached static dependency SHA-256 mismatch: $($package.name)"
    }
    return $destination
}
function File-Receipt([string]$path) {
    return [ordered]@{
        path = [IO.Path]::GetFullPath($path)
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
function Restore-SourceInput($inputFile, [string]$directory) {
    $destination = Join-Path $directory $inputFile.file
    if (-not (Test-Path -LiteralPath $destination)) {
        try {
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri $inputFile.url -OutFile "$destination.part"
            if ((Get-FileHash "$destination.part" -Algorithm SHA256).Hash -ne $inputFile.sha256) {
                throw "Corresponding-source SHA-256 mismatch: $($inputFile.file)"
            }
            Move-Item -LiteralPath "$destination.part" -Destination $destination
        } finally {
            if (Test-Path -LiteralPath "$destination.part") { Remove-Item -LiteralPath "$destination.part" -Force }
        }
    }
    $receipt = File-Receipt $destination
    if ($receipt.sha256 -ne $inputFile.sha256) {
        throw "Cached corresponding-source SHA-256 mismatch: $($inputFile.file)"
    }
    return $receipt
}

$priorPath = $env:PATH
try {
    if ($ForDistribution -and (-not $lock.distribution.ready -or
        -not $lock.toolchain.sourceProvenanceComplete -or $ProtocolOnly -or $SkipTests)) {
        throw "Distribution is blocked. See native\dependencies.json distribution.remainingGaps; production=true means real implementation, NOT permission to publish."
    }
    $env:PATH = "$ToolchainDirectory;$priorPath"
    $gcc = Join-Path $ToolchainDirectory "gcc.exe"
    $gxx = Join-Path $ToolchainDirectory "g++.exe"
    $objdump = Join-Path $ToolchainDirectory "objdump.exe"
    $nm = Join-Path $ToolchainDirectory "nm.exe"
    $ar = Join-Path $ToolchainDirectory "ar.exe"
    if ((& $gcc -dumpmachine) -ne "x86_64-w64-mingw32") { throw "An x64 UCRT MinGW toolchain is required." }
    $defines = "" | & $gcc -dM -E -x c -include _mingw.h -
    if ($LASTEXITCODE -ne 0 -or -not ($defines -match "^#define _UCRT(?:\s|$)")) {
        throw "An x64 UCRT compiler is required; an MSVCRT compiler cannot consume this SDK."
    }
    $head = & git -C $vendor rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $lock.protocol.commit) { throw "Pinned protocol checkout is missing or has the wrong commit." }
    $dirty = & git -C $vendor status --porcelain
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw "Vendor source must remain pristine." }
    $sourceInputs = Join-Path $build "sources"
    New-Item -ItemType Directory -Force -Path $build, $sdk, $sourceInputs, (Join-Path $build "downloads") | Out-Null
    $manifestPath = Join-Path $build "link-manifest.json"
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    $provenancePath = Join-Path $build "source-provenance.json"
    if (Test-Path -LiteralPath $provenancePath) { Remove-Item -LiteralPath $provenancePath -Force }
    $mergedArchive = Join-Path $build "libmirrorme-native.a"
    if (Test-Path -LiteralPath $mergedArchive) { Remove-Item -LiteralPath $mergedArchive -Force }
    $packageReceipts = @()
    foreach ($package in $lock.packages) {
        $archive = Verified-Archive $package
        $entries = & tar -tf $archive
        if ($LASTEXITCODE -ne 0) { throw "Cannot inspect static SDK archive." }
        $selected = @($entries | Where-Object {
            $_ -match "^ucrt64/include/(openssl|plist)/.+" -or
            $_ -match "^ucrt64/lib/lib(crypto|plist-2\.0)\.a$" -or
            $_ -match "^ucrt64/share/licenses/.+"
        } | Where-Object { -not $_.EndsWith("/") })
        if (-not $selected.Count) { throw "Static SDK archive has no required entries." }
        Invoke-Tool tar (@("-xf", $archive, "-C", $sdk) + $selected)
        $packageSources = Join-Path $sourceInputs $package.name
        New-Item -ItemType Directory -Force -Path $packageSources | Out-Null
        Invoke-Tool tar @("-xf", $archive, "-C", $packageSources, ".PKGINFO", ".BUILDINFO")
        $buildInfo = Get-Content (Join-Path $packageSources ".BUILDINFO")
        $recipeHash = @($buildInfo | Where-Object { $_ -match "^pkgbuild_sha256sum = " } |
            ForEach-Object { ($_ -split " = ", 2)[1] })
        if ($recipeHash.Count -ne 1 -or $recipeHash[0] -ne $package.recipeSha256FromBuildInfo) {
            throw "Binary package and corresponding-source recipe do not match: $($package.name)"
        }
        $files = @()
        foreach ($inputFile in $package.sourceInputs) {
            $files += Restore-SourceInput $inputFile $packageSources
            if ($inputFile.file -match "\.tar\.(gz|bz2|xz)$") {
                $sourceTar = Join-Path $packageSources $inputFile.file
                $tarEntries = & tar -tf $sourceTar
                if ($LASTEXITCODE -ne 0) { throw "Cannot inspect corresponding source archive." }
                $notices = @($tarEntries | Where-Object {
                    $_ -match "^[^/]+/(COPYING[^/]*|LICENSE[^/]*|NOTICE[^/]*|AUTHORS[^/]*)$"
                })
                if (-not $notices.Count) { throw "Corresponding source lacks expected root license notices." }
                Invoke-Tool tar (@("-xf", $sourceTar, "-C", $packageSources) + $notices)
            }
        }
        $packageReceipts += [ordered]@{
            name = $package.name
            binaryPackage = (File-Receipt $archive)
            packageInfo = (File-Receipt (Join-Path $packageSources ".PKGINFO"))
            buildInfo = (File-Receipt (Join-Path $packageSources ".BUILDINFO"))
            recipeCommit = $package.recipeCommit
            recipeMatchesBinaryBuildInfo = $true
            sourceInputs = $files
            notices = @(Get-ChildItem -LiteralPath $packageSources -Recurse -File |
                Where-Object { $_.Name -match "^(COPYING|LICENSE|NOTICE|AUTHORS)" } |
                ForEach-Object { File-Receipt $_.FullName })
            sourceRebuildExecuted = $false
        }
    }
    $sourceArchive = Join-Path $build "protocol-source.tar"
    Invoke-Tool git @("-C", $vendor, "archive", "--format=tar", "--output=$sourceArchive", $lock.protocol.commit)
    if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    Invoke-Tool tar @("-xf", $sourceArchive, "-C", $source)
    Invoke-Tool python @((Join-Path $native "patches\prepare-protocol.py"), $source)
    # Snapshot actual uncommitted native inputs; a git revision alone would not
    # describe this build. The final application/Go source release is separate.
    $applicationSources = Join-Path $sourceInputs "mirrorme"
    if (Test-Path -LiteralPath $applicationSources) { Remove-Item -LiteralPath $applicationSources -Recurse -Force }
    $nativeInputs = @(Get-ChildItem -LiteralPath $native -Recurse -File | Select-Object -ExpandProperty FullName)
    $nativeInputs += @("scripts\build-native.ps1", "scripts\build-audio-codecs.ps1",
        "receiver\resources\mirrorme.ico", "receiver\tests\blue-frame.h264", "LICENSE") |
        ForEach-Object { Join-Path $root $_ }
    $nativeReceipts = @()
    foreach ($path in $nativeInputs) {
        $relative = $path.Substring($root.Length + 1)
        $copy = Join-Path $applicationSources $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $copy) | Out-Null
        Copy-Item -LiteralPath $path -Destination $copy
        $receipt = File-Receipt $copy
        $receipt.original = $path
        $nativeReceipts += $receipt
    }
    $remainingGaps = @($lock.distribution.remainingGaps)
    $audioProvenance = $null
    if (-not $ProtocolOnly) {
        $audioRoot = Split-Path -Parent $AudioSdkDirectory
        $audioManifest = Join-Path $audioRoot "build-manifest.json"
        $audioLock = Get-Content (Join-Path $native "audio-dependencies.json") -Raw | ConvertFrom-Json
        if (Test-Path -LiteralPath $audioManifest) {
            $audioInfo = Get-Content $audioManifest -Raw | ConvertFrom-Json
            if ($audioInfo.sourceSha256 -ne $audioLock.ffmpeg.sourceSha256 -or
                $audioInfo.strictPacketPatchSha256 -ne $audioLock.ffmpeg.strictPacketPatchSha256 -or
                $audioInfo.dependencyManifestSha256 -ne (File-Receipt (Join-Path $native "audio-dependencies.json")).sha256 -or
                $audioInfo.buildScriptSha256 -ne (File-Receipt (Join-Path $root "scripts\build-audio-codecs.ps1")).sha256 -or
                $audioInfo.avcodecSha256 -ne (File-Receipt (Join-Path $AudioSdkDirectory "lib\libavcodec.a")).sha256 -or
                $audioInfo.avutilSha256 -ne (File-Receipt (Join-Path $AudioSdkDirectory "lib\libavutil.a")).sha256) {
                throw "Audio source/build receipt does not match the current pinned inputs and static libraries. Rebuild audio."
            }
            $audioSource = Join-Path $audioRoot "ffmpeg-$($audioLock.ffmpeg.version).tar.xz"
            if (-not (Test-Path -LiteralPath $audioSource) -or
                (File-Receipt $audioSource).sha256 -ne $audioLock.ffmpeg.sourceSha256) {
                throw "The pinned FFmpeg corresponding source archive is missing or mismatched."
            }
            $audioProvenance = [ordered]@{
                sourceArchive = (File-Receipt $audioSource)
                buildManifest = (File-Receipt $audioManifest)
                configurationAndNotices = (Join-Path $AudioSdkDirectory "share\licenses\ffmpeg")
                staticLibrariesMatchSourceBuildReceipt = $true
            }
        } else {
            $remainingGaps += "Selected audio SDK has no matching build-manifest.json; codec source provenance cannot be established."
        }
    }
    $mode = if ($ProtocolOnly) { "ON" } else { "OFF" }
    $cmakeBuild = Join-Path $build "cmake"
    Invoke-Tool cmake @("-S", $native, "-B", $cmakeBuild, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=$Configuration", "-DCMAKE_C_COMPILER=$gcc", "-DCMAKE_CXX_COMPILER=$gxx",
        "-DMM_PROTOCOL_ONLY=$mode", "-DAUDIO_SDK_DIR=$AudioSdkDirectory")
    Invoke-Tool cmake @("--build", $cmakeBuild, "--parallel", "$Parallel")
    $symbols = & $nm -u (Join-Path $build "lib\libmirrorme.a") (Join-Path $build "lib\libairplay.a")
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect native static symbols." }
    if ($symbols -cmatch "\b(?:__imp_)?(?:gst_|g_main_|g_object_|g_signal_|g_timeout_|g_idle_|DNSServiceRegister|DNSServiceRefDeallocate)") {
        throw "The new backend contains a forbidden GStreamer, GLib, or Bonjour dependency."
    }
    $probe = Join-Path $build "tests\protocol_tests.exe"
    $imports = @(& $objdump -p $probe | Select-String "DLL Name:" | ForEach-Object { ($_.Line -split "DLL Name:\s*")[1].Trim() })
    if ($LASTEXITCODE -ne 0 -or -not $imports.Count) {
        throw "Native receiver probe import audit failed or returned no DLL imports."
    }
    $systemDll = "^(api-ms-win-.*|ext-ms-win-.*|KERNEL32|USER32|GDI32|ADVAPI32|WS2_32|CRYPT32|bcrypt|DNSAPI|IPHLPAPI|OLE32|OLEAUT32|SHLWAPI|MF|MFPlat|MFReadWrite|D3D11|DXGI|PROPSYS|AVRT|KSUSER|WINMM|SHELL32|ntdll|msvcrt|ucrtbase)\.dll$"
    foreach ($dll in $imports) { if ($dll -notmatch $systemDll) { throw "Non-system DLL import in static receiver probe: $dll" } }
    # MinGW can emit an unused import stub for executable exports from a static
    # dependency. It is not an input library and must not enter the cgo bundle.
    foreach ($testName in @("protocol_tests", "protocol_media_invariants", "protocol_receive_bounds")) {
        $testImportStub = Join-Path $build "lib\lib$testName.dll.a"
        if (Test-Path -LiteralPath $testImportStub) { Remove-Item -LiteralPath $testImportStub -Force }
    }
    if (-not $SkipTests) { Invoke-Tool ctest @("--test-dir", $cmakeBuild, "--output-on-failure") }
    $mergedWindowsLibraries = @("dnsapi", "mfplat", "mfuuid", "ole32", "oleaut32", "uuid",
        "user32", "gdi32", "ksuser", "ws2_32", "iphlpapi", "crypt32", "bcrypt", "advapi32")
    $mergedImports = @()
    $archiveReceipts = @()
    if (-not $ProtocolOnly) {
        $inputs = @(
            (Join-Path $build "lib\libmirrorme.a"),
            (Join-Path $build "lib\libairplay.a"),
            (Join-Path $build "lib\libplayfair.a"),
            (Join-Path $build "lib\libllhttp.a"),
            (Join-Path $AudioSdkDirectory "lib\libavcodec.a"),
            (Join-Path $AudioSdkDirectory "lib\libavutil.a"),
            (Join-Path $sdk "ucrt64\lib\libplist-2.0.a"),
            (Join-Path $sdk "ucrt64\lib\libcrypto.a")
        )
        foreach ($runtime in @("libstdc++.a", "libwinpthread.a", "libgcc.a", "libgcc_eh.a")) {
            $runtimePath = & $gcc "-print-file-name=$runtime"
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $runtimePath)) {
                throw "Missing static compiler runtime: $runtime"
            }
            $inputs += [IO.Path]::GetFullPath($runtimePath.Replace("/", "\"))
        }
        # MRI uses bare filenames to avoid drive-letter/backslash parsing and
        # Windows argument length limits. These are build-local intermediates.
        $mergeInputs = @()
        Push-Location $build
        try {
            $mri = @("create libmirrorme-native.a")
            for ($i = 0; $i -lt $inputs.Count; $i++) {
                $file = "mirrorme-merge-$i.a"
                Copy-Item -LiteralPath $inputs[$i] -Destination $file -Force
                $mergeInputs += $file
                $receipt = File-Receipt (Join-Path $build $file)
                $receipt.path = $inputs[$i]
                $archiveReceipts += $receipt
                $mri += "addlib $file"
            }
            $mri += @("save", "end")
            ($mri -join "`n") | & $ar -M
            if ($LASTEXITCODE -ne 0) { throw "Merging native static archives failed." }
            Invoke-Tool $ar @("s", "libmirrorme-native.a")
        } finally {
            foreach ($file in $mergeInputs) { Remove-Item -LiteralPath $file -Force }
            Pop-Location
        }
        $mergedProbe = Join-Path $build "tests\protocol_merged_tests.exe"
        $linkArguments = @("-static", "-static-libgcc",
            (Join-Path $cmakeBuild "CMakeFiles\protocol_tests.dir\tests\protocol_tests.cpp.obj"),
            (Join-Path $cmakeBuild "CMakeFiles\protocol_tests.dir\tests\protocol_resource.rc.obj"),
            $mergedArchive)
        $linkArguments += @($mergedWindowsLibraries | ForEach-Object { "-l$_" })
        $linkArguments += @("-o", $mergedProbe)
        # GCC (not G++) proves libstdc++ is really in the merged archive.
        Invoke-Tool $gcc $linkArguments
        $mergedImports = @(& $objdump -p $mergedProbe | Select-String "DLL Name:" |
            ForEach-Object { ($_.Line -split "DLL Name:\s*")[1].Trim() })
        if ($LASTEXITCODE -ne 0 -or -not $mergedImports.Count) {
            throw "Merged receiver probe import audit failed or returned no DLL imports."
        }
        foreach ($dll in $mergedImports) {
            if ($dll -notmatch $systemDll) { throw "Non-system DLL import in merged receiver probe: $dll" }
        }
        if (-not $SkipTests) {
            Invoke-MergedProbe $mergedProbe $cmakeBuild
        }
    }
    foreach ($receipt in $nativeReceipts) {
        if ((File-Receipt $receipt.original).sha256 -ne $receipt.sha256) {
            throw "Native source changed during compilation; rebuild to obtain matching source receipts."
        }
    }
    $provenance = [ordered]@{
        schemaVersion = 1
        distributionReady = $false
        remainingGaps = $remainingGaps
        protocol = [ordered]@{
            commit = $lock.protocol.commit
            originalArchive = (File-Receipt $sourceArchive)
            transformations = (File-Receipt (Join-Path $native "patches\prepare-protocol.py"))
            compiledSourceDirectory = $source
            notices = @("LICENSE", "lib\llhttp\LICENSE-MIT", "lib\playfair\LICENSE.md") |
                ForEach-Object { File-Receipt (Join-Path $source $_) }
        }
        nativeInputSnapshot = $nativeReceipts
        packageSources = $packageReceipts
        audio = $audioProvenance
        compiler = (File-Receipt $gcc)
        compilerVersion = (& $gcc -dumpfullversion)
        compilerRuntimeSourceProvenanceComplete = $lock.toolchain.sourceProvenanceComplete
        staticArchiveInputs = $archiveReceipts
        compileCommands = (File-Receipt (Join-Path $cmakeBuild "compile_commands.json"))
        cmakeCache = (File-Receipt (Join-Path $cmakeBuild "CMakeCache.txt"))
    }
    $provenance | ConvertTo-Json -Depth 8 | Set-Content $provenancePath -Encoding UTF8
    if ($ForDistribution -and -not $provenance.distributionReady) {
        throw "Build succeeded for development, but corresponding-source publication remains blocked."
    }
    $manifest = [ordered]@{
        protocolCommit = $lock.protocol.commit
        production = (-not $ProtocolOnly)
        distributionReady = $provenance.distributionReady
        sourceProvenance = (File-Receipt $provenancePath)
        includeDirectory = (Join-Path $native "include")
        archiveDirectory = (Join-Path $build "lib")
        staticSdk = (Join-Path $sdk "ucrt64")
        audioSdk = $AudioSdkDirectory
        linkOrder = @("mirrorme", "airplay", "playfair", "llhttp", "avcodec", "avutil", "plist-2.0", "crypto")
        runtimeFlags = @("-static", "-static-libgcc", "-static-libstdc++")
        windowsLibraries = @("dnsapi", "mfplat", "mf", "mfuuid", "wmcodecdspuuid", "d3d11", "dxgi", "dxguid",
            "ole32", "oleaut32", "uuid", "user32", "gdi32", "avrt", "propsys", "shlwapi", "ksuser",
            "winpthread", "ws2_32", "iphlpapi", "crypt32", "bcrypt", "advapi32")
        probeImports = @($imports)
        mergedArchive = $(if ($ProtocolOnly) { $null } else { $mergedArchive })
        mergedArchiveSha256 = $(if ($ProtocolOnly) { $null } else { (Get-FileHash $mergedArchive -Algorithm SHA256).Hash.ToLowerInvariant() })
        mergedWindowsLibraries = $mergedWindowsLibraries
        mergedProbeImports = $mergedImports
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath -Encoding UTF8
    Copy-Item (Join-Path $native "dependencies.json") (Join-Path $build "dependencies.json") -Force
    Write-Host "Static native build complete; production=$(-not $ProtocolOnly); distributionReady=false. No old engine files were modified."
    Write-Warning "Do not publish this development build. See build\native\source-provenance.json for remaining source/rebuild gaps."
} finally { $env:PATH = $priorPath }
