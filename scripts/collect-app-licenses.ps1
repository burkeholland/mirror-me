#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ApplicationVersion = "",
    [switch]$Force,
    [switch]$UseSourceOnlySender,
    [string]$NativeSourceRoot = "",
    [string]$ApplicationSourceRoot = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Copy-RequiredFile([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required license file is missing: $Source"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Copy-LicenseFiles([string]$Source, [string]$Destination, [string]$Component) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "License source for $Component is missing: $Source"
    }
    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force |
        Where-Object {
            $_.Extension -eq '.nuspec' -or
                $_.Name -match '(^|[-_.])(LICENSE|LICENCE|COPYING|NOTICE|NOTICES|COPYRIGHT)(?:$|[._-])'
        })
    if (-not $files.Count) {
        throw "No license, notice, or NuGet license metadata was found for $Component in $Source"
    }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        if ($relative.StartsWith('..', [StringComparison]::Ordinal)) {
            throw "License path escaped its source directory: $relative"
        }
        $destinationPath = Join-Path $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
    }
    return $files.Count
}

function Copy-NativeLicenseTree([string]$Source, [string]$InventoryPath, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Native license source is missing: $Source"
    }
    if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        throw "Native source inventory is missing: $InventoryPath"
    }
    $inventory = @(Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json)
    $expectedFiles = @($inventory | Where-Object {
        ([string]$_.path).StartsWith('licenses/', [StringComparison]::OrdinalIgnoreCase)
    })
    if (-not $expectedFiles.Count) {
        throw "Native source inventory has no licenses tree: $InventoryPath"
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)
    if ($actualFiles.Count -ne $expectedFiles.Count) {
        throw "Native licenses tree does not match its inventory: expected $($expectedFiles.Count) files, found $($actualFiles.Count)."
    }

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $expectedFiles) {
        $inventoryPath = [string]$item.path
        $relativePath = $inventoryPath.Substring('licenses/'.Length).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
            -not $paths.Add($relativePath)) {
            throw "Native source inventory contains an unsafe or duplicate license path: $inventoryPath"
        }
        $sourcePath = Join-Path $Source $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Native license file is missing from its source tree: $inventoryPath"
        }
        $sourceFile = Get-Item -LiteralPath $sourcePath
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceFile.Length -ne [long]$item.bytes -or $sourceHash -ne [string]$item.sha256) {
            throw "Native license file does not match its source inventory: $inventoryPath"
        }
        $destinationPath = Join-Path $Destination $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    $nativePinsPath = Join-Path $root 'native\source-dependencies.json'
    if (-not (Test-Path -LiteralPath $nativePinsPath -PathType Leaf)) {
        throw "Native source pins are missing: $nativePinsPath"
    }
    $nativePins = Get-Content -LiteralPath $nativePinsPath -Raw | ConvertFrom-Json
    $noticeResources = @($nativePins.noticeResources)
    if (-not $noticeResources.Count) {
        throw "Native source pins have no notice resources: $nativePinsPath"
    }
    foreach ($resource in $noticeResources) {
        $relativePath = ([string]$resource.file).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Native source pins contain an unsafe notice path: $($resource.file)"
        }
        $noticePath = Join-Path $Destination $relativePath
        if (-not (Test-Path -LiteralPath $noticePath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $noticePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$resource.sha256) {
            throw "Pinned native notice is missing or has the wrong hash: $($resource.file)"
        }
    }
    return $expectedFiles.Count
}

Push-Location $root
try {
    $config = Get-Content -LiteralPath 'wails.json' -Raw | ConvertFrom-Json
    if (-not $ApplicationVersion) {
        $ApplicationVersion = [string]$config.info.productVersion
    }
    if ($ApplicationVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Application version must use major.minor.patch format.'
    }
    $applicationSourceRoot = if (-not $ApplicationSourceRoot) {
        $root
    } elseif ([IO.Path]::IsPathRooted($ApplicationSourceRoot)) {
        [IO.Path]::GetFullPath($ApplicationSourceRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $ApplicationSourceRoot))
    }
    if (-not (Test-Path -LiteralPath (Join-Path $applicationSourceRoot 'go.mod') -PathType Leaf)) {
        throw "Application source root does not contain go.mod: $applicationSourceRoot"
    }

    $destination = Join-Path $root "build\licenses\$ApplicationVersion"
    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            throw "License tree already exists: $destination. Use -Force to regenerate it."
        }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $application = Join-Path $destination 'application'
    $moduleLicenses = Join-Path $application 'go-modules'
    $licenseFile = Join-Path $root 'packaging\msix\COPYING-GPL-3.0.txt'
    Copy-RequiredFile $licenseFile (Join-Path $destination 'COPYING-GPL-3.0.txt')
    Copy-RequiredFile $licenseFile (Join-Path $application 'COPYING-GPL-3.0.txt')
    Copy-RequiredFile (Join-Path $applicationSourceRoot 'LICENSE') (Join-Path $application 'LICENSE')
    Copy-RequiredFile (Join-Path $applicationSourceRoot 'THIRD-PARTY-NOTICES.md') `
        (Join-Path $application 'THIRD-PARTY-NOTICES.md')

    Push-Location $applicationSourceRoot
    try {
        Invoke-Checked 'go' @('mod', 'download', 'all')
        Invoke-Checked 'go' @('mod', 'verify')
        $moduleLines = @(& go list -m -f '{{.Path}}|{{.Version}}|{{.Dir}}' all)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not enumerate the locked Go module graph.'
        }
    } finally {
        Pop-Location
    }
    $moduleCount = 0
    foreach ($line in $moduleLines) {
        $fields = $line -split '\|', 3
        if ($fields.Count -ne 3 -or -not $fields[1]) { continue }
        if (-not $fields[2] -or -not (Test-Path -LiteralPath $fields[2] -PathType Container)) {
            throw "Go module source is unavailable: $($fields[0])@$($fields[1])"
        }
        $moduleDestination = Join-Path $moduleLicenses "$($fields[0])@$($fields[1])"
        $null = Copy-LicenseFiles $fields[2] $moduleDestination "$($fields[0])@$($fields[1])"
        $moduleCount++
    }
    if (-not $moduleCount) {
        throw 'The Go module graph did not contain any dependency sources.'
    }

    $goRoot = (& go env GOROOT).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $goRoot) {
        throw 'Could not locate the Go runtime source tree.'
    }
    Copy-RequiredFile (Join-Path $goRoot 'LICENSE') (Join-Path $application 'go-runtime\LICENSE')
    Copy-RequiredFile (Join-Path $goRoot 'PATENTS') (Join-Path $application 'go-runtime\PATENTS')
    Copy-RequiredFile (Join-Path $root 'frontend\node_modules\lucide\LICENSE') (Join-Path $application 'lucide\LICENSE')

    $nativeBundleRoot = if (-not $NativeSourceRoot) {
        Join-Path $root 'build\native-sources\bundle'
    } elseif ([IO.Path]::IsPathRooted($NativeSourceRoot)) {
        [IO.Path]::GetFullPath($NativeSourceRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $NativeSourceRoot))
    }
    $nativeSource = Join-Path $nativeBundleRoot 'licenses'
    $nativeInventoryPath = Join-Path $nativeBundleRoot 'file-inventory.json'
    $senderPackageBase = Join-Path $root 'build\native-sender'
    if ($UseSourceOnlySender) {
        $senderPackageBase = Join-Path $senderPackageBase 'source-release'
    } else {
        $senderPackageBase = Join-Path $senderPackageBase 'source'
    }
    $senderSource = if ($UseSourceOnlySender) {
        Join-Path $senderPackageBase 'licenses'
    } else {
        Join-Path $root 'build\bin\sender\licenses'
    }
    $senderPackageRoot = Join-Path $senderPackageBase 'packages'
    $senderPackageInventoryPath = Join-Path $senderSource 'packages.json'
    if (-not (Test-Path -LiteralPath $senderPackageInventoryPath -PathType Leaf)) {
        throw "Sender dependency inventory is missing: $senderPackageInventoryPath"
    }
    $senderPackages = @(Get-Content -LiteralPath $senderPackageInventoryPath -Raw | ConvertFrom-Json)
    if (-not $senderPackages.Count) {
        throw "Sender dependency inventory is empty: $senderPackageInventoryPath"
    }
    foreach ($package in $senderPackages) {
        if ([string]$package.package -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9.+-]+$' -or
            [string]$package.archive -notmatch '^[A-Za-z0-9._+-]+\.nupkg$') {
            throw "Sender dependency inventory contains an unsafe package entry: $($package | ConvertTo-Json -Compress)"
        }
        $archive = Join-Path $senderPackageRoot ([string]$package.archive)
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$package.sha256) {
            throw "Sender NuGet archive is missing or does not match its inventory: $($package.package)"
        }
        $noticeDirectory = Join-Path $senderSource ([string]$package.package).Replace('/', '-')
        $packageNotices = @(Get-ChildItem -LiteralPath $noticeDirectory -Recurse -File -Force -ErrorAction SilentlyContinue)
        $hasLicenseFile = @($packageNotices | Where-Object {
            $_.Name -match '(^|[-_.])(LICENSE|LICENCE|COPYING|NOTICE|NOTICES|COPYRIGHT)(?:$|[._-])'
        }).Count -gt 0
        $hasLicenseMetadata = @($packageNotices | Where-Object {
            $_.Extension -eq '.nuspec' -and
            (Get-Content -LiteralPath $_.FullName -Raw) -match '(?is)<license(?:\s|>)|<licenseUrl>'
        }).Count -gt 0
        if (-not $hasLicenseFile -and -not $hasLicenseMetadata) {
            throw "Sender dependency has no license text or license metadata: $($package.package)"
        }
    }
    if (-not $UseSourceOnlySender) {
        $senderReceiptPath = Join-Path $root 'build\bin\sender\sender.build.json'
        if (-not (Test-Path -LiteralPath $senderReceiptPath -PathType Leaf)) {
            throw "Sender build receipt is missing: $senderReceiptPath"
        }
        $senderReceipt = Get-Content -LiteralPath $senderReceiptPath -Raw | ConvertFrom-Json
        $inventoryHash = (Get-FileHash -LiteralPath $senderPackageInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $licensePattern = '(^|[-_.])(LICENSE|LICENCE|COPYING|NOTICE|NOTICES|COPYRIGHT)(?:$|[._-])'
        $licenseFileCount = @(Get-ChildItem -LiteralPath $senderSource -Recurse -File -Force |
            Where-Object { $_.Name -match $licensePattern -or $_.Extension -eq '.nuspec' }).Count
        if ($senderReceipt.packageCount -ne $senderPackages.Count -or
            $senderReceipt.packageInventorySha256 -ne $inventoryHash -or
            $senderReceipt.licenseFileCount -ne $licenseFileCount) {
            throw 'Sender license and dependency inventories do not match the normal sender build receipt. Rebuild the sender before packaging.'
        }
    }
    $null = Copy-NativeLicenseTree $nativeSource $nativeInventoryPath (Join-Path $destination 'native')
    $null = Copy-LicenseFiles $senderSource (Join-Path $destination 'sender') 'WinPlay and NuGet dependencies'
    Copy-RequiredFile (Join-Path $root 'native\AUDIO-NOTICES.txt') (Join-Path $destination 'native\AUDIO-NOTICES.txt')
    Copy-RequiredFile (Join-Path $root 'native\NATIVE-SOURCE-NOTICES.txt') (Join-Path $destination 'native\NATIVE-SOURCE-NOTICES.txt')
    Copy-RequiredFile (Join-Path $root 'sender\README.md') (Join-Path $destination 'sender\README.md')

    $required = @(
        'COPYING-GPL-3.0.txt',
        'application\LICENSE',
        'application\COPYING-GPL-3.0.txt',
        'application\THIRD-PARTY-NOTICES.md',
        'application\go-runtime\LICENSE',
        'application\go-runtime\PATENTS',
        'application\lucide\LICENSE',
        'native\protocol\LICENSE',
        'native\protocol\lib\playfair\LICENSE.md',
        'native\protocol\lib\llhttp\LICENSE-MIT',
        'native\CC0-1.0.txt',
        'native\gcc-COPYING3',
        'native\mingw-DISCLAIMER',
        'native\mingw-DISCLAIMER.PD',
        'native\ffmpeg\audio_ffmpeg_strict.patch',
        'native\ffmpeg\audio-dependencies.json',
        'native\ffmpeg\build-audio-codecs.ps1',
        'native\ffmpeg\config.h',
        'native\ffmpeg\config.mak',
        'native\ffmpeg\COPYING.LGPLv2.1',
        'native\openssl\LICENSE.txt',
        'native\libplist\COPYING.LESSER',
        'native\NATIVE-SOURCE-NOTICES.txt',
        'native\AUDIO-NOTICES.txt',
        'sender\WinPlay-LICENSE.txt',
        'sender\WinPlay-THIRD-PARTY-NOTICES.md',
        'sender\README.md'
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $destination $relative) -PathType Leaf)) {
            throw "Required license-tree entry is missing: $relative"
        }
    }

    $inventory = @(Get-ChildItem -LiteralPath $destination -Recurse -File -Force |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = [IO.Path]::GetRelativePath($destination, $_.FullName).Replace('\', '/')
                bytes = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    $inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'file-inventory.json') -Encoding utf8
    Write-Host "Generated license tree: $destination"
    Write-Host "Included $($inventory.Count) license and notice files for $moduleCount Go modules."
} finally {
    Pop-Location
}
