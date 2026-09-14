[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?$')]
    [string]$Version = "0.1.1-preview.1"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$output = Join-Path $root "build\releases"
$stageRoot = Join-Path $root "build\release-stage"
New-Item -ItemType Directory -Force -Path $output, $stageRoot | Out-Null
$stage = Join-Path $stageRoot ([guid]::NewGuid().ToString("N"))
$application = Join-Path $stage "windows"
$source = Join-Path $stage "source"
New-Item -ItemType Directory -Force -Path (Join-Path $application "engine"), (Join-Path $source "receiver"), (Join-Path $source "scripts") | Out-Null

try {
    $app = Join-Path $root "build\bin\MirrorMe.exe"
    $receiver = Join-Path $root "engine\mirrorme-receiver.exe"
    $vendor = Join-Path $root "receiver\vendor\libuxplay"
    $lock = Get-Content -LiteralPath (Join-Path $root "receiver\dependencies.json") -Raw | ConvertFrom-Json
    foreach ($path in @($app, $receiver, (Join-Path $vendor "LICENSE"))) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Build input is missing: $path" }
    }
    $expectedVersion = $Version.Split('-')[0]
    foreach ($binary in @($app, $receiver)) {
        $info = (Get-Item -LiteralPath $binary).VersionInfo
        $actualVersion = [version]::new($info.ProductMajorPart, $info.ProductMinorPart, $info.ProductBuildPart, $info.ProductPrivatePart)
        if ($actualVersion.ToString(3) -ne $expectedVersion -or $actualVersion.Revision -ne 0) {
            throw "Build $binary for $expectedVersion before packaging; its embedded version is '$actualVersion'."
        }
    }
    if ((git -C $vendor rev-parse HEAD) -ne $lock.uxplay.commit -or $LASTEXITCODE -ne 0) {
        throw "The native source does not match its pinned commit."
    }
    if ((git -C $vendor status --porcelain) -or $LASTEXITCODE -ne 0) {
        throw "The pinned native checkout must remain pristine."
    }
    Copy-Item -LiteralPath $app -Destination $application
    Copy-Item -LiteralPath $receiver -Destination (Join-Path $application "engine")
    foreach ($name in @("README.md", "LICENSE", "THIRD-PARTY-NOTICES.md")) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination $application
    }
    Copy-Item -LiteralPath (Join-Path $vendor "LICENSE") -Destination (Join-Path $application "LICENSE-RECEIVER.txt")

    $notices = New-Object System.Text.StringBuilder
    [void]$notices.AppendLine("Go application dependency notices")
    $goRoot = & go env GOROOT
    if ($LASTEXITCODE -ne 0) { throw "Go is required to collect its dependency notices." }
    [void]$notices.AppendLine("`nGo standard library`n" + (Get-Content -LiteralPath (Join-Path $goRoot "LICENSE") -Raw))
    Push-Location $root
    try { $modules = & go list -m -f '{{if .Dir}}{{.Path}}|{{.Dir}}{{end}}' all }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "Could not identify Go dependency licenses." }
    foreach ($module in $modules) {
        if (-not $module -or $module.StartsWith("MirrorMe|")) { continue }
        $parts = $module.Split('|', 2)
        $licenses = @(Get-ChildItem -LiteralPath $parts[1] -File | Where-Object { $_.Name -match '^(LICEN[SC]E|COPYING|NOTICE)(\.|$)' })
        if ($licenses.Count -eq 0) { throw "No root license notice found for $($parts[0]); review it before distribution." }
        [void]$notices.AppendLine("`n============================================================`n$($parts[0])")
        foreach ($license in $licenses) {
            [void]$notices.AppendLine("`n$($license.Name)`n" + (Get-Content -LiteralPath $license.FullName -Raw))
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $application "LICENSES-GO.txt"), $notices.ToString(), [System.Text.UTF8Encoding]::new($false))

    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root "receiver") -File)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $source "receiver")
    }
    foreach ($folder in @("patches", "tests", "resources")) {
        Copy-Item -LiteralPath (Join-Path $root "receiver\$folder") -Destination (Join-Path $source "receiver") -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $root "scripts\build-receiver.ps1") -Destination (Join-Path $source "scripts")
    Copy-Item -LiteralPath (Join-Path $vendor "LICENSE") -Destination (Join-Path $source "LICENSE")
    if ((git -C $vendor rev-parse --is-shallow-repository) -eq "true") {
        & git -C $vendor fetch --quiet --unshallow origin
        if ($LASTEXITCODE -ne 0) { throw "Could not prepare complete native source history." }
    }
    $bundle = Join-Path $source "receiver\libuxplay.bundle"
    & git -C $vendor bundle create $bundle HEAD
    if ($LASTEXITCODE -ne 0) { throw "Could not archive exact native source." }
    & git -C $vendor bundle verify $bundle
    if ($LASTEXITCODE -ne 0) { throw "Native source bundle verification failed." }

    $windowsZip = Join-Path $output "MirrorMe-windows-x64.zip"
    $sourceZip = Join-Path $output "MirrorMe-receiver-source.zip"
    Compress-Archive -Path (Join-Path $application "*") -DestinationPath $windowsZip -Force
    Compress-Archive -Path (Join-Path $source "*") -DestinationPath $sourceZip -Force
    $runtime = Get-Content -LiteralPath (Join-Path $root "receiver\runtime.json") -Raw | ConvertFrom-Json
    $manifest = [ordered]@{
        version = $Version
        platform = "windows-amd64"
        unsigned = $true
        physicalIPhoneVerified = $false
        applicationSha256 = (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash.ToLowerInvariant()
        receiverSha256 = (Get-FileHash -LiteralPath $receiver -Algorithm SHA256).Hash.ToLowerInvariant()
        nativeSourceCommit = $lock.uxplay.commit
        runtimeDownload = $runtime
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output "release-manifest.json") -Encoding UTF8
    $checksums = foreach ($name in @("MirrorMe-windows-x64.zip", "MirrorMe-receiver-source.zip", "release-manifest.json")) {
        "$((Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash.ToLowerInvariant())  $name"
    }
    $checksums | Set-Content -LiteralPath (Join-Path $output "SHA256SUMS.txt") -Encoding ASCII
    Write-Host "Preview release $Version packaged at $output"
    Write-Host "The public Windows ZIP contains no downloaded third-party DLL bundle."
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
