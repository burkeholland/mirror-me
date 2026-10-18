[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root "build\native-sender"
$vendor = Join-Path $work "vendor"
$output = Join-Path $root "build\bin\sender"
$lock = Get-Content -LiteralPath (Join-Path $root "sender\dependency.json") -Raw | ConvertFrom-Json
$patch = Join-Path $root "sender\$($lock.patch)"

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}

foreach ($tool in @("git", "dotnet")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Desktop casting requires '$tool' at build time. Install the .NET 8 SDK or later and Git."
    }
}
New-Item -ItemType Directory -Force -Path $work, $output | Out-Null
if (-not (Test-Path -LiteralPath $vendor)) {
    Invoke-Checked "git" @("clone", "--quiet", "--no-checkout", $lock.repository, $vendor)
    Invoke-Checked "git" @("-C", $vendor, "checkout", "--quiet", "--detach", $lock.commit)
}
$commit = & git -C $vendor rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit -ne $lock.commit) { throw "Sender sources do not match the pinned commit." }
$patchStats = & git -C $vendor apply --numstat $patch
if ($LASTEXITCODE -ne 0) { throw "Could not inspect the sender compatibility patch." }
$patchedFiles = @($patchStats | ForEach-Object { ($_ -split "`t", 3)[2] })
function Register-PatchFiles {
    # Intent-to-add includes new patched files in diff verification without
    # staging their contents or accepting any other untracked source files.
    foreach ($file in $patchedFiles) {
        if (Test-Path -LiteralPath (Join-Path $vendor $file)) {
            Invoke-Checked "git" @("-C", $vendor, "add", "--intent-to-add", "--", $file)
        }
    }
}
Register-PatchFiles
$diff = (& git -C $vendor diff --no-ext-diff --binary) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "Could not inspect sender sources." }
$expected = (Get-Content -LiteralPath $patch -Raw).Replace("`r`n", "`n").TrimEnd()
if ($diff.TrimEnd() -eq "") {
    Invoke-Checked "git" @("-C", $vendor, "apply", "--check", $patch)
    Invoke-Checked "git" @("-C", $vendor, "apply", $patch)
    Register-PatchFiles
} elseif ($diff.Replace("`r`n", "`n").TrimEnd() -ne $expected) {
    throw "Sender sources contain changes other than the checked-in compatibility patch."
}
Invoke-Checked "git" @("-C", $vendor, "diff", "--cached", "--exit-code")
$untracked = & git -C $vendor ls-files --others --exclude-standard -- src
if ($LASTEXITCODE -ne 0 -or $untracked) { throw "Unexpected untracked sender source files." }

$source = Join-Path $work "source"
New-Item -ItemType Directory -Force -Path $source | Out-Null
Invoke-Checked "git" @("-C", $vendor, "archive", "--format=tar", "--output=$(Join-Path $source 'WinPlay-source.tar')", $lock.commit)
$wrapperFiles = @("Program.cs", "MirrorMe.Sender.csproj", "packages.lock.json", "dependency.json", "winplay.patch", "README.md")
foreach ($file in $wrapperFiles) {
    Copy-Item -LiteralPath (Join-Path $root "sender\$file") -Destination $source -Force
}
Copy-Item -LiteralPath (Join-Path $root "sender\tests") -Destination $source -Recurse -Force
Copy-Item -LiteralPath $PSCommandPath -Destination $source -Force

Invoke-Checked "dotnet" @("publish", (Join-Path $root "sender\MirrorMe.Sender.csproj"), "-c", "Release",
    "-r", "win-x64", "--self-contained", "true", "-p:EnableWindowsTargeting=true",
    "-p:RestoreLockedMode=true", "-o", $output, "--nologo", "-v:quiet")
$after = (& git -C $vendor diff --no-ext-diff --binary) -join "`n"
if ($LASTEXITCODE -ne 0 -or $after.Replace("`r`n", "`n").TrimEnd() -ne $expected) {
    throw "Sender source changed during the build."
}
foreach ($file in $wrapperFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $root "sender\$file") -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $source $file) -Algorithm SHA256).Hash) {
        throw "Sender wrapper inputs changed during the build."
    }
}
$licenses = Join-Path $output "licenses"
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $vendor "LICENSE") -Destination (Join-Path $licenses "WinPlay-LICENSE.txt") -Force
Copy-Item -LiteralPath (Join-Path $vendor "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $licenses "WinPlay-THIRD-PARTY-NOTICES.md") -Force
Copy-Item -LiteralPath (Join-Path $root "sender\README.md") -Destination $output -Force
$assets = Get-Content -LiteralPath (Join-Path $root "sender\obj\project.assets.json") -Raw | ConvertFrom-Json
$packagePaths = [System.Collections.Generic.HashSet[string]]::new()
foreach ($library in $assets.libraries.PSObject.Properties) {
    if ($library.Value.type -eq "package") { $null = $packagePaths.Add($library.Value.path) }
}
foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
    foreach ($download in $framework.Value.downloadDependencies) {
        $version = $download.version.Trim('[', ']').Split(',')[0].Trim()
        $null = $packagePaths.Add("$($download.name.ToLowerInvariant())/$version")
    }
}
$packages = Join-Path $source "packages"
New-Item -ItemType Directory -Force -Path $packages | Out-Null
$inventory = foreach ($packagePath in $packagePaths) {
    $directory = $null
    foreach ($cache in $assets.packageFolders.PSObject.Properties.Name) {
        $candidate = Join-Path $cache $packagePath
        if (Test-Path -LiteralPath $candidate) { $directory = $candidate; break }
    }
    if (-not $directory) { throw "Cannot retain sender dependency $packagePath from the NuGet cache." }
    $archive = @(Get-ChildItem -LiteralPath $directory -Filter "*.nupkg" -File)
    if ($archive.Count -ne 1) { throw "Cannot identify the original NuGet archive for $packagePath." }
    Copy-Item -LiteralPath $archive[0].FullName -Destination $packages -Force
    $noticeDirectory = Join-Path $licenses ($packagePath.Replace('/', '-'))
    New-Item -ItemType Directory -Force -Path $noticeDirectory | Out-Null
    foreach ($notice in Get-ChildItem -LiteralPath $directory -File -Recurse |
        Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE|THIRD.PARTY)' -or $_.Extension -eq '.nuspec' }) {
        $relative = $notice.FullName.Substring($directory.Length).TrimStart('\', '/')
        $destination = Join-Path $noticeDirectory $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $notice.FullName -Destination $destination -Force
    }
    [ordered]@{ package = $packagePath; archive = $archive[0].Name; sha256 = (Get-FileHash $archive[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $source "packages.json") -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $source "packages.json") -Destination $licenses -Force
[ordered]@{
    backend = "winplay"
    protocol = 1
    sourceCommit = $lock.commit
    patchSha256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
    wrapperSha256 = (Get-FileHash -LiteralPath (Join-Path $source "Program.cs") -Algorithm SHA256).Hash.ToLowerInvariant()
    executableSha256 = (Get-FileHash -LiteralPath (Join-Path $output "MirrorMe.Sender.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceArchiveSha256 = (Get-FileHash -LiteralPath (Join-Path $source "WinPlay-source.tar") -Algorithm SHA256).Hash.ToLowerInvariant()
    dotnetSdk = (& dotnet --version)
    physicalAppleTVVerified = $false
    distributionApproved = $false
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output "sender.build.json") -Encoding UTF8
Write-Host "Desktop sender: $output"
Write-Host "Retained sender source: $source. Include matching source and full dependency notices before distribution."
