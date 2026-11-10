#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $PSScriptRoot 'rebuild\application'),
    [string]$ToolchainDirectory = 'C:\Strawberry\c\bin'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Destination = [IO.Path]::GetFullPath($Destination)
$sourceRoot = [IO.Path]::GetFullPath($PSScriptRoot)
if (Test-Path -LiteralPath $Destination) {
    throw "Refusing to overwrite $Destination. Choose a new -Destination."
}

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

$inventory = Get-Content -LiteralPath (Join-Path $sourceRoot 'file-inventory.json') -Raw | ConvertFrom-Json
foreach ($file in $inventory) {
    $path = [IO.Path]::GetFullPath((Join-Path $sourceRoot $file.path.Replace('/', '\')))
    if (-not $path.StartsWith($sourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Source inventory contains an invalid path: $($file.path)"
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) {
        throw "Source file checksum mismatch: $($file.path)"
    }
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
Invoke-Checked 'tar' @('-xf', (Join-Path $sourceRoot 'application-source.tar'), '-C', $Destination)
$pins = Get-Content -LiteralPath (Join-Path $Destination 'native\dependencies.json') -Raw | ConvertFrom-Json
$vendor = Join-Path $Destination 'receiver\vendor\libuxplay'
New-Item -ItemType Directory -Force -Path (Split-Path $vendor -Parent) | Out-Null
Invoke-Checked 'git' @('clone', '--quiet', (Join-Path $sourceRoot 'protocol.git.bundle'), $vendor)
Invoke-Checked 'git' @('-C', $vendor, 'checkout', '--quiet', '--detach', $pins.protocol.commit)
Copy-Item -LiteralPath (Join-Path $sourceRoot 'NATIVE-SOURCE-NOTICES.txt') `
    -Destination (Join-Path $Destination 'native\NATIVE-SOURCE-NOTICES.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'sender\README.md') `
    -Destination (Join-Path $Destination 'sender\README.md') -Force

$nativeSources = Join-Path $sourceRoot 'native-sources'
New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'build\native-sources') | Out-Null
Copy-Item -LiteralPath $nativeSources -Destination (Join-Path $Destination 'build\native-sources\bundle') -Recurse
$audioSource = Join-Path $Destination 'build\native-audio'
New-Item -ItemType Directory -Force -Path $audioSource | Out-Null
Copy-Item -LiteralPath (Join-Path $nativeSources 'audio\ffmpeg-8.0.1.tar.xz') -Destination $audioSource
foreach ($library in @('openssl', 'libplist')) {
    $recipes = Join-Path $Destination "build\native\sources\$library"
    New-Item -ItemType Directory -Force -Path $recipes | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $nativeSources "recipes\$library") -File |
        Copy-Item -Destination $recipes
}

$oldModules = $env:GOMODCACHE
try {
    $env:GOMODCACHE = Join-Path $Destination 'build\go-modules'
    $downloadCache = Join-Path $env:GOMODCACHE 'cache\download'
    New-Item -ItemType Directory -Force -Path $downloadCache | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'go-modules\cache\download') -Force |
        Copy-Item -Destination $downloadCache -Recurse
    Push-Location $Destination
    try {
        $lucide = Get-Content -LiteralPath (Join-Path $sourceRoot 'frontend\provenance.json') -Raw | ConvertFrom-Json
        $lucideArchive = Join-Path $sourceRoot "frontend\lucide-$($lucide.version).tgz"
        Invoke-Checked 'npm' @('cache', 'add', $lucideArchive)
        Invoke-Checked 'npm' @('ci', '--prefix', 'frontend')
        & (Join-Path $Destination 'scripts\build-app.ps1') -ToolchainDirectory $ToolchainDirectory
    } finally {
        Pop-Location
    }
} finally {
    $env:GOMODCACHE = $oldModules
}

$executable = Join-Path $Destination 'build\bin\MirrorMe.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "The rebuild did not produce the application executable: $executable"
}
Write-Host "Rebuilt executable: $executable"
