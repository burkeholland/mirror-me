[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\.exe$')]
    [string]$OutputName = "MirrorMe.exe",
    [string]$ToolchainDirectory = "C:\Strawberry\c\bin",
    [switch]$SkipNativeBuild
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$oldPath = $env:PATH
$oldCgo = $env:CGO_ENABLED
$oldBinary = $env:MIRRORME_NATIVE_BINARY

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}

Push-Location $root
try {
    $env:PATH = "$ToolchainDirectory;$env:ProgramFiles\Go\bin;$env:PATH"
    $env:CGO_ENABLED = "1"
    foreach ($tool in @("go", "node", "npm", "gcc", "objdump", "git", "cmake", "ninja", "python", "tar", "gmake")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Required build tool '$tool' is missing. Install the documented Windows build prerequisites."
        }
    }
    $goPath = & go env GOPATH
    if ($LASTEXITCODE -ne 0) { throw "Could not locate the Go tools directory." }
    $env:PATH = "$(Join-Path ($goPath.Split(';')[0]) 'bin');$env:PATH"
    $wails = Get-Command wails -ErrorAction SilentlyContinue
    if (-not $wails) { throw "Install Wails v2.15.0 before building MirrorMe." }

    if (-not $SkipNativeBuild) {
        $lock = Get-Content -LiteralPath (Join-Path $root "native\dependencies.json") -Raw | ConvertFrom-Json
        $vendor = Join-Path $root "receiver\vendor\libuxplay"
        if (-not (Test-Path -LiteralPath $vendor)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vendor) | Out-Null
            Invoke-Checked "git" @("clone", "--quiet", "--no-checkout", "--filter=blob:none", $lock.protocol.repository, $vendor)
            Invoke-Checked "git" @("-C", $vendor, "checkout", "--quiet", "--detach", $lock.protocol.commit)
        }
        & (Join-Path $PSScriptRoot "build-audio-codecs.ps1")
        & (Join-Path $PSScriptRoot "build-native.ps1") -ToolchainDirectory $ToolchainDirectory
    }
    $manifestPath = Join-Path $root "build\native\link-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Build the native libraries before using -SkipNativeBuild."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if (-not $manifest.production -or
        (Get-FileHash -LiteralPath $manifest.mergedArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.mergedArchiveSha256) {
        throw "A matching, production native archive is required; protocol-only test stubs cannot ship."
    }

    Invoke-Checked "npm" @("--prefix", "frontend", "run", "build")
    # Force relinking because Go does not track external static archive changes.
    # Do not clean build/bin: it may also contain the user's previous build.
    Invoke-Checked $wails.Source @("build", "-f", "-s", "-m", "-nosyncgomod",
        "-platform", "windows/amd64", "-o", $OutputName,
        "-webview2", "error", "-nocolour")
    if ((Get-FileHash -LiteralPath $manifest.mergedArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.mergedArchiveSha256) {
        throw "Native code changed during the app build. Rebuild after native compilation finishes."
    }

    $env:MIRRORME_NATIVE_BINARY = Join-Path $root "build\bin\$OutputName"
    Invoke-Checked "go" @("test", "-run", "^TestNativeApplicationRunsFromOneFile$", "-count=1", ".")
    foreach ($notice in @("LICENSE", "README.md", "THIRD-PARTY-NOTICES.md",
        "native\AUDIO-NOTICES.txt", "native\NATIVE-SOURCE-NOTICES.txt")) {
        Copy-Item -LiteralPath (Join-Path $root $notice) -Destination (Join-Path $root "build\bin") -Force
    }
    $version = (Get-Item -LiteralPath $env:MIRRORME_NATIVE_BINARY).VersionInfo
    [ordered]@{
        version = "{0}.{1}.{2}" -f $version.ProductMajorPart, $version.ProductMinorPart, $version.ProductBuildPart
        backend = "native"
        executable = $OutputName
        applicationSha256 = (Get-FileHash -LiteralPath $env:MIRRORME_NATIVE_BINARY -Algorithm SHA256).Hash.ToLowerInvariant()
        nativeArchiveSha256 = $manifest.mergedArchiveSha256
        protocolSourceCommit = $manifest.protocolCommit
        singleFileWorkerVerified = $true
        physicalIPhoneVerified = $false
        distributionApproved = $false
    } | ConvertTo-Json | Set-Content -LiteralPath "$env:MIRRORME_NATIVE_BINARY.build.json" -Encoding UTF8
    Write-Host "Self-contained application: $env:MIRRORME_NATIVE_BINARY"
    Write-Host "No receiver folder is required. Physical iPhone verification remains a separate release check."
} finally {
    Pop-Location
    $env:PATH = $oldPath
    $env:CGO_ENABLED = $oldCgo
    $env:MIRRORME_NATIVE_BINARY = $oldBinary
}
