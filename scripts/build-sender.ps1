[CmdletBinding()]
param(
    [switch]$SourceOnly,
    [string]$SourceRoot = ''
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$senderRoot = Join-Path $root "sender"
if ($SourceRoot) {
    if (-not $SourceOnly) {
        throw "-SourceRoot can only be used with -SourceOnly."
    }
    if (-not [IO.Path]::IsPathRooted($SourceRoot)) {
        $SourceRoot = Join-Path $root $SourceRoot
    }
    $senderRoot = [IO.Path]::GetFullPath($SourceRoot)
}
if (-not (Test-Path -LiteralPath $senderRoot -PathType Container)) {
    throw "Sender source directory is missing: $senderRoot"
}
$script:NuGetPackagingLoaded = $false
$work = Join-Path $root "build\native-sender"
$vendor = Join-Path $work "vendor"
$output = Join-Path $root "build\bin\sender"
$lock = Get-Content -LiteralPath (Join-Path $senderRoot "dependency.json") -Raw | ConvertFrom-Json
$patch = Join-Path $senderRoot $lock.patch

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE." }
}

function Get-LockedPackages([string]$Path) {
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $packages = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($framework in $manifest.dependencies.PSObject.Properties) {
        foreach ($dependency in $framework.Value.PSObject.Properties) {
            $entry = $dependency.Value
            if ($entry.type -notin @("Direct", "Transitive")) { continue }
            if (-not $entry.resolved -or -not $entry.contentHash) {
                throw "Sender dependency lock is missing a resolved version or content hash for $($dependency.Name)."
            }
            $id = [string]$dependency.Name
            $version = [string]$entry.resolved
            $packagePath = "$($id.ToLowerInvariant())/$($version.ToLowerInvariant())"
            if ($seen.Add($packagePath)) {
                $packages.Add([pscustomobject]@{
                    path = $packagePath
                    id = $id
                    version = $version
                    contentHash = [string]$entry.contentHash
                })
            }
        }
    }
    if (-not $packages.Count) { throw "Sender dependency lock contains no NuGet packages: $Path" }
    return @($packages.ToArray())
}

function Get-NuGetContentHash([string]$Path) {
    if (-not $script:NuGetPackagingLoaded) {
        $dotnetPath = (Get-Command dotnet -ErrorAction Stop).Source
        $sdkRoot = Join-Path (Split-Path -Parent $dotnetPath) "sdk"
        $assemblies = @(Get-ChildItem -LiteralPath $sdkRoot -Directory |
            Sort-Object { [version]$_.Name } -Descending |
            ForEach-Object { Join-Path $_.FullName "NuGet.Packaging.dll" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        if (-not $assemblies.Count) {
            throw "NuGet.Packaging.dll was not found under the .NET SDK at $sdkRoot."
        }
        [Reflection.Assembly]::LoadFrom($assemblies[0]) | Out-Null
        $script:NuGetPackagingLoaded = $true
    }
    $reader = [NuGet.Packaging.PackageArchiveReader]::new($Path)
    try { return $reader.GetContentHash([Threading.CancellationToken]::None, $null) }
    finally { $reader.Dispose() }
}

function Get-NuGetArchiveSha512([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA512]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash($stream)) }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-LockedPackageArchive([object]$Package, [string]$DestinationDirectory) {
    $id = [string]$Package.id
    $version = [string]$Package.version
    if ($id -notmatch '^[A-Za-z0-9._-]+$' -or $version -notmatch '^[A-Za-z0-9.+-]+$') {
        throw "Sender dependency lock contains an unsafe NuGet package coordinate: $id/$version"
    }
    $normalizedId = $id.ToLowerInvariant()
    $normalizedVersion = $version.ToLowerInvariant()
    $archiveName = "$normalizedId.$normalizedVersion.nupkg"
    $destination = Join-Path $DestinationDirectory $archiveName
    $cacheRoots = [Collections.Generic.List[string]]::new()
    if ($env:NUGET_PACKAGES) { $cacheRoots.Add($env:NUGET_PACKAGES) }
    if ($env:USERPROFILE) { $cacheRoots.Add((Join-Path $env:USERPROFILE ".nuget\packages")) }
    $cachedArchive = $null
    foreach ($cacheRoot in $cacheRoots) {
        $candidate = Join-Path (Join-Path (Join-Path $cacheRoot $normalizedId) $normalizedVersion) $archiveName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $cachedArchive = $candidate
            break
        }
    }
    if ($cachedArchive) {
        Copy-Item -LiteralPath $cachedArchive -Destination $destination -Force
    } else {
        $uris = @(
            "https://api.nuget.org/v3-flatcontainer/$normalizedId/$normalizedVersion/$archiveName",
            "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/flat2/$normalizedId/$normalizedVersion/$archiveName"
        )
        $downloadErrors = [Collections.Generic.List[string]]::new()
        $downloaded = $false
        foreach ($uri in $uris) {
            try {
                Invoke-WebRequest -Uri $uri -OutFile $destination -ErrorAction Stop
                $downloaded = $true
                break
            } catch {
                $downloadErrors.Add("$uri : $($_.Exception.Message)")
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloaded) {
            throw "Could not download locked NuGet package $id/$version. $($downloadErrors -join '; ')"
        }
    }
    $actualHash = Get-NuGetContentHash $destination
    if ($actualHash -ne [string]$Package.contentHash) {
        throw "NuGet SHA-512 mismatch for $id/$version; expected $($Package.contentHash), got $actualHash."
    }
    return $destination
}

function Get-AssetPackageArchive(
    [string]$PackagePath,
    [object]$Assets,
    [string]$DestinationDirectory,
    [switch]$RequireHash
) {
    if ($PackagePath -notmatch '^([A-Za-z0-9._-]+)/([A-Za-z0-9.+-]+)$') {
        throw "Sender restore assets contain an unsafe NuGet package path: $PackagePath"
    }
    $id = $Matches[1].ToLowerInvariant()
    $version = $Matches[2].ToLowerInvariant()
    $archiveName = "$id.$version.nupkg"
    $destination = Join-Path $DestinationDirectory $archiveName
    $cachedArchive = $null
    foreach ($cache in $Assets.packageFolders.PSObject.Properties.Name) {
        $candidate = Join-Path (Join-Path $cache $PackagePath) $archiveName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $cachedArchive = $candidate
            break
        }
    }

    $uriBases = @(
        "https://api.nuget.org/v3-flatcontainer/$id/$version",
        "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/flat2/$id/$version"
    )
    $downloadedFrom = ''
    if ($cachedArchive) {
        Copy-Item -LiteralPath $cachedArchive -Destination $destination -Force
    } else {
        $downloadErrors = [Collections.Generic.List[string]]::new()
        foreach ($uriBase in $uriBases) {
            try {
                Invoke-WebRequest -Uri "$uriBase/$archiveName" -OutFile $destination -ErrorAction Stop
                $downloadedFrom = $uriBase
                break
            } catch {
                $downloadErrors.Add("$uriBase : $($_.Exception.Message)")
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloadedFrom) {
            throw "Could not obtain NuGet package $PackagePath. $($downloadErrors -join '; ')"
        }
    }

    $expectedHash = ''
    if ($cachedArchive -and (Test-Path -LiteralPath "$cachedArchive.sha512" -PathType Leaf)) {
        $expectedHash = (Get-Content -LiteralPath "$cachedArchive.sha512" -Raw).Trim()
    }
    if (-not $expectedHash) {
        $hashSources = if ($downloadedFrom) { @($downloadedFrom) } else { $uriBases }
        $hashErrors = [Collections.Generic.List[string]]::new()
        foreach ($uriBase in $hashSources) {
            try {
                $response = Invoke-WebRequest -Uri "$uriBase/$archiveName.sha512" -ErrorAction Stop
                $expectedHash = [string]$response.Content.Trim()
                if ($expectedHash) { break }
            } catch {
                $hashErrors.Add("$uriBase : $($_.Exception.Message)")
            }
        }
        if (-not $expectedHash) {
            if ($RequireHash) {
                throw "NuGet feed did not provide a SHA-512 sidecar for $PackagePath; source-release package provenance cannot be verified. $($hashErrors -join '; ')"
            }
            Write-Warning "NuGet feed did not provide a SHA-512 sidecar for $PackagePath. Recording the downloaded archive digest; $($hashErrors -join '; ')"
        }
    }
    if ($expectedHash) {
        $actualHash = Get-NuGetArchiveSha512 $destination
        if ($actualHash -ne $expectedHash) {
            throw "NuGet archive SHA-512 mismatch for $PackagePath; expected $expectedHash, got $actualHash."
        }
    }
    return $destination
}

function Copy-NuGetNotices([string]$ArchivePath, [string]$DestinationDirectory) {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $destinationRoot = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\') + '\'
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name -or
                ($entry.Name -notmatch '^(?i:LICENSE|COPYING|NOTICE|THIRD.PARTY)' -and
                    [IO.Path]::GetExtension($entry.Name) -ne '.nuspec')) {
                continue
            }
            $relative = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)') {
                throw "NuGet package contains an unsafe notice path: $($entry.FullName)"
            }
            $destination = [IO.Path]::GetFullPath((Join-Path $DestinationDirectory $relative))
            if (-not $destination.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "NuGet package notice escaped its destination: $($entry.FullName)"
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            $input = $entry.Open()
            try {
                $output = [IO.File]::Open($destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            } finally { $input.Dispose() }
        }
    } finally { $archive.Dispose() }
}

$requiredTools = @("git", "dotnet")
foreach ($tool in $requiredTools) {
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

$sourceName = if ($SourceOnly) { "source-release" } else { "source" }
$source = Join-Path $work $sourceName
if (Test-Path -LiteralPath $source) {
    Remove-Item -LiteralPath $source -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $source | Out-Null
Invoke-Checked "git" @("-C", $vendor, "archive", "--format=tar", "--output=$(Join-Path $source 'WinPlay-source.tar')", $lock.commit)
$wrapperFiles = @("Program.cs", "MirrorMe.Sender.csproj", "packages.lock.json", "dependency.json", "winplay.patch", "README.md")
foreach ($file in $wrapperFiles) {
    Copy-Item -LiteralPath (Join-Path $senderRoot $file) -Destination $source -Force
}
Copy-Item -LiteralPath (Join-Path $senderRoot "tests") -Destination $source -Recurse -Force
Copy-Item -LiteralPath $PSCommandPath -Destination $source -Force

if (-not $SourceOnly) {
    Invoke-Checked "dotnet" @("publish", (Join-Path $senderRoot "MirrorMe.Sender.csproj"), "-c", "Release",
        "-r", "win-x64", "--self-contained", "true", "-p:EnableWindowsTargeting=true",
        "-p:RestoreLockedMode=true", "-o", $output, "--nologo", "-v:quiet")
}
$after = (& git -C $vendor diff --no-ext-diff --binary) -join "`n"
if ($LASTEXITCODE -ne 0 -or $after.Replace("`r`n", "`n").TrimEnd() -ne $expected) {
    throw "Sender source changed during the build."
}
foreach ($file in $wrapperFiles) {
    if ((Get-FileHash -LiteralPath (Join-Path $senderRoot $file) -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $source $file) -Algorithm SHA256).Hash) {
        throw "Sender wrapper inputs changed during the build."
    }
}
$licenses = if ($SourceOnly) { Join-Path $source "licenses" } else { Join-Path $output "licenses" }
if (Test-Path -LiteralPath $licenses) {
    Remove-Item -LiteralPath $licenses -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $vendor "LICENSE") -Destination (Join-Path $licenses "WinPlay-LICENSE.txt") -Force
Copy-Item -LiteralPath (Join-Path $vendor "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $licenses "WinPlay-THIRD-PARTY-NOTICES.md") -Force
if (-not $SourceOnly) {
    Copy-Item -LiteralPath (Join-Path $senderRoot "README.md") -Destination $output -Force
}
$packagePaths = [System.Collections.Generic.HashSet[string]]::new()
$sourceOnlyDownloadPaths = [System.Collections.Generic.HashSet[string]]::new()
$lockedPackagesByPath = @{}
$assets = $null
if ($SourceOnly) {
    $lockedPackages = @(Get-LockedPackages (Join-Path $senderRoot "packages.lock.json"))
    foreach ($package in $lockedPackages) {
        $null = $packagePaths.Add([string]$package.path)
        $lockedPackagesByPath[[string]$package.path] = $package
    }

    $restoreProject = Join-Path $work "source-restore"
    if (Test-Path -LiteralPath $restoreProject) {
        Remove-Item -LiteralPath $restoreProject -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $restoreProject | Out-Null
    foreach ($file in @("MirrorMe.Sender.csproj", "packages.lock.json")) {
        Copy-Item -LiteralPath (Join-Path $senderRoot $file) -Destination $restoreProject -Force
    }
    Invoke-Checked "dotnet" @("restore", (Join-Path $restoreProject "MirrorMe.Sender.csproj"),
        "-r", "win-x64", "-p:EnableWindowsTargeting=true", "-p:RestoreLockedMode=true",
        "-p:WinPlaySource=$vendor", "--nologo", "-v:quiet")

    $assetsPath = Join-Path $restoreProject "obj\project.assets.json"
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
        throw "Fresh locked sender restore did not produce dependency assets: $assetsPath"
    }
    $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
    $logsProperty = $assets.PSObject.Properties["logs"]
    $restoreErrors = @()
    if ($logsProperty) {
        $restoreErrors = @($logsProperty.Value | Where-Object { $_.level -eq "Error" })
    }
    if (@($restoreErrors).Count) {
        throw "Fresh locked sender restore contains errors: $(($restoreErrors | ForEach-Object { $_.message }) -join '; ')"
    }
    foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
        $downloadProperty = $framework.Value.PSObject.Properties["downloadDependencies"]
        if (-not $downloadProperty) { continue }
        foreach ($download in $downloadProperty.Value) {
            $versionRange = [string]$download.version
            if ($versionRange -notmatch '^\[([^,\]]+),\s*([^\]]+)\]$') {
                throw "Fresh sender restore did not resolve an exact NuGet package version for $($download.name): $versionRange"
            }
            $minimum = $Matches[1].Trim()
            $maximum = $Matches[2].Trim()
            $id = [string]$download.name
            if ($minimum -ne $maximum -or $id -notmatch '^[A-Za-z0-9._-]+$' -or
                $minimum -notmatch '^[A-Za-z0-9.+-]+$') {
                throw "Fresh sender restore contains an unresolved or unsafe NuGet package coordinate: $id $versionRange"
            }
            $packagePath = "$($id.ToLowerInvariant())/$minimum"
            $null = $sourceOnlyDownloadPaths.Add($packagePath)
            $null = $packagePaths.Add($packagePath)
        }
    }
    foreach ($requiredPackageId in @("microsoft.netcore.app.runtime.win-x64")) {
        $requiredPackages = @($sourceOnlyDownloadPaths | Where-Object {
            $_.StartsWith("$requiredPackageId/", [StringComparison]::OrdinalIgnoreCase)
        })
        if ($requiredPackages.Count -ne 1) {
            throw "Fresh locked sender restore must resolve exactly one $requiredPackageId package for win-x64; found $($requiredPackages.Count)."
        }
    }
} else {
    $assetsPath = Join-Path $senderRoot "obj\project.assets.json"
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
        throw "Sender restore assets are missing: $assetsPath. Restore the sender project before collecting its dependencies."
    }
    $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
    foreach ($library in $assets.libraries.PSObject.Properties) {
        if ($library.Value.type -eq "package") {
            $null = $packagePaths.Add([string]$library.Value.path)
        }
    }
    foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
        foreach ($download in $framework.Value.downloadDependencies) {
            $version = $download.version.Trim('[', ']').Split(',')[0].Trim()
            $null = $packagePaths.Add("$($download.name.ToLowerInvariant())/$version")
        }
    }
}
$packages = Join-Path $source "packages"
New-Item -ItemType Directory -Force -Path $packages | Out-Null
$inventory = foreach ($packagePath in $packagePaths) {
    if ($lockedPackagesByPath.ContainsKey($packagePath)) {
        $packageArchive = Get-LockedPackageArchive $lockedPackagesByPath[$packagePath] $packages
    } elseif ($SourceOnly -and $sourceOnlyDownloadPaths.Contains($packagePath)) {
        $packageArchive = Get-AssetPackageArchive $packagePath $assets $packages -RequireHash
    } elseif ($SourceOnly) {
        throw "Sender dependency is neither locked nor a fresh PackageDownload: $packagePath"
    } else {
        $packageArchive = Get-AssetPackageArchive $packagePath $assets $packages
    }
    $noticeDirectory = Join-Path $licenses ($packagePath.Replace('/', '-'))
    Copy-NuGetNotices $packageArchive $noticeDirectory
    $packageNotices = @(Get-ChildItem -LiteralPath $noticeDirectory -Recurse -File -Force)
    $packageLicenseText = @($packageNotices | Where-Object {
        $_.Name -match '(^|[-_.])(LICENSE|LICENCE|COPYING|NOTICE|NOTICES|COPYRIGHT)(?:$|[._-])'
    })
    $packageNuspecs = @($packageNotices | Where-Object { $_.Extension -eq ".nuspec" })
    $hasNuspecLicenseMetadata = @($packageNuspecs | Where-Object {
        (Get-Content -LiteralPath $_.FullName -Raw) -match '(?is)<license(?:\s|>)|<licenseUrl>'
    }).Count -gt 0
    if (-not $packageLicenseText.Count -and -not $hasNuspecLicenseMetadata) {
        throw "NuGet dependency $packagePath has no license text or license metadata."
    }
    [ordered]@{
        package = $packagePath
        archive = [IO.Path]::GetFileName($packageArchive)
        sha256 = (Get-FileHash $packageArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        sha512 = Get-NuGetArchiveSha512 $packageArchive
    }
}
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $source "packages.json") -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $source "packages.json") -Destination $licenses -Force
$licenseFilePattern = '(^|[-_.])(LICENSE|LICENCE|COPYING|NOTICE|NOTICES|COPYRIGHT)(?:$|[._-])'
$senderLicenseFileCount = @(Get-ChildItem -LiteralPath $licenses -Recurse -File -Force |
    Where-Object { $_.Name -match $licenseFilePattern -or $_.Extension -eq ".nuspec" }).Count
if (-not $senderLicenseFileCount) { throw "No sender license files were collected: $licenses" }
$packageInventorySha256 = (Get-FileHash -LiteralPath (Join-Path $licenses "packages.json") -Algorithm SHA256).Hash.ToLowerInvariant()
if ($SourceOnly) {
    Write-Host "Retained sender sources, locked dependencies, and fresh runtime/reference packages: $source"
} else {
    [ordered]@{
        backend = "winplay"
        protocol = 1
        sourceCommit = $lock.commit
        patchSha256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()
        wrapperSha256 = (Get-FileHash -LiteralPath (Join-Path $source "Program.cs") -Algorithm SHA256).Hash.ToLowerInvariant()
        executableSha256 = (Get-FileHash -LiteralPath (Join-Path $output "MirrorMe.Sender.exe") -Algorithm SHA256).Hash.ToLowerInvariant()
        sourceArchiveSha256 = (Get-FileHash -LiteralPath (Join-Path $source "WinPlay-source.tar") -Algorithm SHA256).Hash.ToLowerInvariant()
        packageCount = @($inventory).Count
        packageInventorySha256 = $packageInventorySha256
        licenseFileCount = $senderLicenseFileCount
        dotnetSdk = (& dotnet --version)
        physicalAppleTVVerified = $false
        distributionApproved = $false
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output "sender.build.json") -Encoding UTF8
    Write-Host "Desktop sender: $output"
    Write-Host "Retained sender source: $source. Include matching source and full dependency notices before distribution."
}
