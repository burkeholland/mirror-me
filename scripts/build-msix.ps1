[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ApplicationVersion = "",
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$PackageVersion = "",
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{2,49}$')]
    [string]$IdentityName = "BurkeHolland.MirrorMe.Development",
    [ValidateNotNullOrEmpty()]
    [string]$Publisher = "CN=Burke Holland",
    [ValidateNotNullOrEmpty()]
    [string]$PublisherDisplayName = "Burke Holland",
    [ValidateNotNullOrEmpty()]
    [string]$ProductDisplayName = "MirrorMe",
    [string]$Executable = "",
    [string]$OutputPath = "",
    [switch]$BuildApplication,
    [switch]$StoreSubmission,
    [string]$ToolchainDirectory = "C:\Strawberry\c\bin",
    [string]$CertificatePath = "",
    [string]$CertificatePasswordEnvironmentVariable = "MIRRORME_MSIX_CERT_PASSWORD",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

function Get-SourceTreeChanges {
    $status = @(& git status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the application source tree."
    }
    return @($status | Where-Object { $_ -notmatch '^\?\? build[\\/]' })
}

function Resolve-WindowsSdkTool([string]$Name) {
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    $candidates = @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName "x64\$Name" } |
        Where-Object { Test-Path -LiteralPath $_ })
    if (-not $candidates.Count) {
        throw "$Name was not found. Install the Windows 11 SDK."
    }
    return $candidates[0]
}

function Convert-ToPackageVersion([string]$InputVersion, [string]$ExplicitPackageVersion) {
    if ($ExplicitPackageVersion) {
        $parts = @($ExplicitPackageVersion.Split('.') | ForEach-Object { [int]$_ })
    } else {
        $applicationParts = @($InputVersion.Split('.') | ForEach-Object { [int]$_ })
        if ($applicationParts.Count -ne 3 -or
            @($applicationParts | Where-Object { $_ -lt 0 -or $_ -gt 65534 }).Count) {
            throw "Application version must contain three integers from 0 through 65534."
        }
        $parts = @(($applicationParts[0] + 1), $applicationParts[1], $applicationParts[2], 0)
    }
    if ($parts.Count -ne 4 -or $parts[0] -eq 0 -or
        @($parts | Where-Object { $_ -lt 0 -or $_ -gt 65535 }).Count) {
        throw "MSIX version must contain four integers from 0 through 65535, and the first must be nonzero."
    }
    if ($parts[3] -ne 0) {
        throw "The fourth MSIX version component is reserved for Microsoft Store use and must be 0."
    }
    return $parts -join '.'
}

function Escape-Xml([string]$Value) {
    return [Security.SecurityElement]::Escape($Value)
}

function Write-SquareAsset(
    [Drawing.Image]$Source,
    [int]$Size,
    [string]$Destination
) {
    $bitmap = [Drawing.Bitmap]::new($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.DrawImage($Source, 0, 0, $Size, $Size)
        } finally {
            $graphics.Dispose()
        }
        $bitmap.Save($Destination, [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
}

Push-Location $root
try {
    $sourceCommit = ''
    $applicationReceipt = $null
    $applicationReceiptVerified = $false
    $sourceTreeCleanAtEnd = $false
    $packageCreated = $false
    $storeApproved = $false
    $collectionReport = $null
    $config = Get-Content -LiteralPath "wails.json" -Raw | ConvertFrom-Json
    if (-not $ApplicationVersion) {
        $ApplicationVersion = [string]$config.info.productVersion
    }
    if ($ApplicationVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Application version must use major.minor.patch format."
    }
    $resolvedPackageVersion = Convert-ToPackageVersion $ApplicationVersion $PackageVersion
    $displayVersion = $ApplicationVersion
    $sourceTag = "v$displayVersion-preview.1"
    $sourceReleaseUrl = "https://github.com/burkeholland/mirror-me/releases/tag/$sourceTag"
    $sourceLines = @(Get-Content -LiteralPath (Join-Path $root "packaging\msix\SOURCE.txt"))
    if ($sourceLines.Count -ne 2 -or
        $sourceLines[0] -ne "MirrorMe $displayVersion source release:" -or
        $sourceLines[1] -ne $sourceReleaseUrl) {
        throw "packaging\msix\SOURCE.txt must link to the exact source tag for $displayVersion."
    }
    $receiptExecutable = if ($Executable) {
        $Executable
    } else {
        Join-Path $root "build\bin\MirrorMe.exe"
    }
    $applicationReceiptPath = "$receiptExecutable.build.json"
    if (Test-Path -LiteralPath $applicationReceiptPath) {
        $applicationReceipt = Get-Content -LiteralPath $applicationReceiptPath -Raw | ConvertFrom-Json
        $applicationReceipt.distributionApproved = $false
        $applicationReceipt | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $applicationReceiptPath -Encoding utf8
    }
    # Readiness describes one approved build, so every run starts from false.
    $generatedDependenciesPath = Join-Path $root "build\native\dependencies.json"
    if (Test-Path -LiteralPath $generatedDependenciesPath) {
        $generatedDependencies = Get-Content -LiteralPath $generatedDependenciesPath -Raw | ConvertFrom-Json
        $generatedDependencies.distribution.ready = $false
        $generatedDependencies | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $generatedDependenciesPath -Encoding utf8
    }

    $sourceReleaseVerified = $false
    $nativeProvenanceVerified = $false
    if ($StoreSubmission) {
        if (-not $BuildApplication) {
            throw "Store packaging requires -BuildApplication so the executable is built from the verified source commit."
        }
        if ($Executable) {
            throw "Store packaging does not accept -Executable; build the canonical executable from the verified source commit."
        }
        $sourceTreeChanges = @(Get-SourceTreeChanges)
        if ($sourceTreeChanges.Count) {
            throw "Store packaging requires a clean committed source tree. Commit or remove source changes before building."
        }
        $sourceCommit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $sourceCommit) {
            throw "Could not identify the source commit for the Store build."
        }

        $nativeDependencies = Get-Content -LiteralPath (Join-Path $root "native\dependencies.json") -Raw |
            ConvertFrom-Json
        if ($nativeDependencies.distribution.ready) {
            throw "native\dependencies.json must keep distribution.ready false; only the Store gate sets it, in build output, after its checks pass."
        }
        $remainingGaps = @($nativeDependencies.distribution.remainingGaps)
        if (-not $nativeDependencies.toolchain.sourceProvenanceComplete -or $remainingGaps.Count) {
            throw "Store packaging is blocked by native source-provenance gaps in native\dependencies.json."
        }
        $rebuildReceipt = Get-Content -LiteralPath (Join-Path $root "native\dependency-rebuild-receipt.json") -Raw |
            ConvertFrom-Json
        $rebuildTests = $rebuildReceipt.nativeTestsAgainstRebuiltLibraries
        $requiredTests = @('protocol_receive_bounds', 'protocol_media_invariants', 'media_flicker', 'protocol_lifecycle')
        $missingTests = @($requiredTests | Where-Object { $_ -notin @($rebuildTests.passed) })
        if (-not $rebuildReceipt.recipesExecuted -or @($rebuildTests.failed).Count -or $missingTests.Count -or
            $rebuildReceipt.protocolPatchSha256 -ne (Get-FileHash -LiteralPath 'native\patches\prepare-protocol.py' -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "native\dependency-rebuild-receipt.json does not record a usable verification rebuild."
        }
        foreach ($package in $nativeDependencies.packages) {
            $rebuilt = @($rebuildReceipt.packages | Where-Object {
                $_.name -eq $package.name -and
                $_.pinnedPackageSha256 -eq $package.sha256 -and
                $_.pkgbuildSha256 -eq $package.recipeSha256FromBuildInfo
            })
            if ($rebuilt.Count -ne 1) {
                throw "The verification rebuild receipt does not cover the pinned $($package.name) package. Rerun scripts\verify-native-dependency-rebuild.ps1."
            }
        }
        $nativeProvenanceVerified = $true

        $collectionReportPath = Join-Path $root "build\native-sources\bundle\collection-report.json"
        if (-not (Test-Path -LiteralPath $collectionReportPath -PathType Leaf)) {
            throw "No native source collection exists for this commit. Run scripts\release-store-build.ps1."
        }
        $collectionReport = Get-Content -LiteralPath $collectionReportPath -Raw | ConvertFrom-Json
        if ($collectionReport.applicationSourceCommit -ne $sourceCommit -or
            $collectionReport.nativeBuildSourceCommit -ne $sourceCommit -or
            -not $collectionReport.nativeBuildSourceTreeClean -or
            -not $collectionReport.nativeBuildChecked) {
            throw "The native archive and source collection are not from a tested Release build of $sourceCommit. Run scripts\release-store-build.ps1."
        }
        & (Join-Path $PSScriptRoot "verify-source-release.ps1") `
            -ApplicationVersion $displayVersion -ExpectedCommit $sourceCommit `
            -ExpectedCollectionReportSha256 (Get-FileHash -LiteralPath $collectionReportPath -Algorithm SHA256).Hash
        $sourceReleaseVerified = $true
    } else {
        $identityParameters = @(
            "IdentityName",
            "Publisher",
            "PublisherDisplayName",
            "ProductDisplayName"
        )
        $identityOverrides = @($identityParameters | Where-Object { $PSBoundParameters.ContainsKey($_) })
        if ($identityOverrides.Count) {
            throw "Partner Center identity values require -StoreSubmission: $($identityOverrides -join ', ')."
        }
    }

    if ($StoreSubmission) {
        foreach ($parameter in @(
            "IdentityName",
            "Publisher",
            "PublisherDisplayName",
            "ProductDisplayName"
        )) {
            if (-not $PSBoundParameters.ContainsKey($parameter)) {
                throw "-$parameter must be supplied from Partner Center for a Store submission package."
            }
        }
        if ($CertificatePath) {
            throw "Microsoft Store submission packages must be left unsigned for Store signing."
        }
    }

    if ($BuildApplication) {
        $applicationBuild = @{ ToolchainDirectory = $ToolchainDirectory }
        # A Store build links the native archive whose hash the published source release records.
        if ($StoreSubmission) { $applicationBuild.SkipNativeBuild = $true }
        & (Join-Path $PSScriptRoot "build-app.ps1") @applicationBuild
    }
    if (-not $Executable) {
        $Executable = Join-Path $root "build\bin\MirrorMe.exe"
    }
    $Executable = (Resolve-Path -LiteralPath $Executable).Path
    $versionInfo = (Get-Item -LiteralPath $Executable).VersionInfo
    $executableVersion = "{0}.{1}.{2}" -f
        $versionInfo.ProductMajorPart, $versionInfo.ProductMinorPart, $versionInfo.ProductBuildPart
    if ($executableVersion -ne $displayVersion) {
        throw "Executable version '$executableVersion' does not match package version '$displayVersion'."
    }
    if ($StoreSubmission) {
        if (-not (Test-Path -LiteralPath $applicationReceiptPath -PathType Leaf)) {
            throw "Store packaging requires the build receipt: $applicationReceiptPath"
        }
        $applicationReceipt = Get-Content -LiteralPath $applicationReceiptPath -Raw | ConvertFrom-Json
        if ($applicationReceipt.version -ne $displayVersion -or
            $applicationReceipt.sourceCommit -ne $sourceCommit -or
            -not $applicationReceipt.sourceTreeClean) {
            throw "Application build receipt does not identify a clean build of source commit $sourceCommit."
        }
        if ([string]$applicationReceipt.nativeArchiveSha256 -ne [string]$collectionReport.nativeMergedArchiveSha256) {
            throw "The application did not link the native archive recorded in the published source release."
        }
        $receiptApplicationHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string]$applicationReceipt.applicationSha256 -ne $receiptApplicationHash) {
            throw "Application executable does not match its build receipt."
        }
        $receiptSenderExecutable = Join-Path (Split-Path -Parent $Executable) "sender\MirrorMe.Sender.exe"
        if (-not (Test-Path -LiteralPath $receiptSenderExecutable -PathType Leaf)) {
            throw "Store packaging requires the built sender executable: $receiptSenderExecutable"
        }
        $receiptSenderHash = (Get-FileHash -LiteralPath $receiptSenderExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([string]$applicationReceipt.senderExecutableSha256 -ne $receiptSenderHash) {
            throw "Sender executable does not match the application build receipt."
        }
        $applicationReceiptVerified = $true
    }
    $makeAppx = Resolve-WindowsSdkTool "makeappx.exe"
    $signTool = if ($CertificatePath) { Resolve-WindowsSdkTool "signtool.exe" } else { "" }
    $stageRoot = Join-Path $root "build\msix\$displayVersion"
    $layout = Join-Path $stageRoot "layout"
    $verification = Join-Path $stageRoot "verification"
    if (-not $OutputPath) {
        $OutputPath = Join-Path $root "build\msix\MirrorMe-$displayVersion-windows-x64.msix"
    } elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $root $OutputPath
    }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)

    if (Test-Path -LiteralPath $OutputPath) {
        if (-not $Force) {
            throw "MSIX already exists: $OutputPath. Use -Force only for a local rebuild."
        }
        Remove-Item -LiteralPath $OutputPath -Force
        if (Test-Path -LiteralPath "$OutputPath.json") { Remove-Item -LiteralPath "$OutputPath.json" -Force }
    }
    foreach ($directory in @($layout, $verification)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $layout "Assets") -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null

    if (-not (Test-Path -LiteralPath (Join-Path $root "build\native-sources\bundle\licenses") -PathType Container)) {
        & (Join-Path $PSScriptRoot "collect-native-sources.ps1") -ToolchainDirectory $ToolchainDirectory
    }
    & (Join-Path $PSScriptRoot "collect-app-licenses.ps1") `
        -ApplicationVersion $displayVersion -Force
    $licenseSource = Join-Path $root "build\licenses\$displayVersion"
    if (-not (Test-Path -LiteralPath $licenseSource -PathType Container)) {
        throw "Generated MSIX license tree is missing: $licenseSource"
    }
    $licenseLayout = Join-Path $layout "licenses"
    New-Item -ItemType Directory -Path $licenseLayout -Force | Out-Null
    Get-ChildItem -LiteralPath $licenseSource -Force |
        Copy-Item -Destination $licenseLayout -Recurse -Force

    Copy-Item -LiteralPath $Executable -Destination (Join-Path $layout "MirrorMe.exe")
    $senderSource = Join-Path (Split-Path -Parent $Executable) "sender"
    $senderExecutable = Join-Path $senderSource "MirrorMe.Sender.exe"
    if (-not (Test-Path -LiteralPath $senderExecutable)) {
        throw "Desktop casting helper is missing: $senderExecutable"
    }
    $senderLayout = Join-Path $layout "sender"
    New-Item -ItemType Directory -Path $senderLayout -Force | Out-Null
    Copy-Item -LiteralPath $senderExecutable -Destination $senderLayout
    foreach ($relativePath in @("README.md", "sender.build.json", "licenses")) {
        $sourcePath = Join-Path $senderSource $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Desktop casting helper artifact is missing: $sourcePath"
        }
        Copy-Item -LiteralPath $sourcePath -Destination $senderLayout -Recurse -Force
    }
    if ($StoreSubmission) {
        # Every pre-package gate has passed. If a later check fails, the unapproved MSIX is deleted.
        $packagedSenderReceiptPath = Join-Path $senderLayout "sender.build.json"
        $packagedSenderReceipt = Get-Content -LiteralPath $packagedSenderReceiptPath -Raw | ConvertFrom-Json
        $packagedSenderReceipt.distributionApproved = $true
        $packagedSenderReceipt | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $packagedSenderReceiptPath -Encoding utf8
    }
    foreach ($relativePath in @(
        "LICENSE",
        "packaging\msix\COPYING-GPL-3.0.txt",
        "PRIVACY.md",
        "THIRD-PARTY-NOTICES.md",
        "native\AUDIO-NOTICES.txt",
        "packaging\msix\SOURCE.txt"
    )) {
        Copy-Item -LiteralPath (Join-Path $root $relativePath) -Destination $layout
    }
    Copy-Item -LiteralPath (Join-Path $root "native\NATIVE-SOURCE-NOTICES.txt") `
        -Destination (Join-Path $layout "NATIVE-SOURCE-NOTICES.txt")

    Add-Type -AssemblyName System.Drawing
    $sourceImage = [Drawing.Image]::FromFile((Join-Path $root "build\appicon.png"))
    try {
        Write-SquareAsset $sourceImage 50 (Join-Path $layout "Assets\StoreLogo.png")
        Write-SquareAsset $sourceImage 44 (Join-Path $layout "Assets\Square44x44Logo.png")
        Write-SquareAsset $sourceImage 150 (Join-Path $layout "Assets\Square150x150Logo.png")
    } finally {
        $sourceImage.Dispose()
    }

    $manifest = Get-Content -LiteralPath "packaging\msix\AppxManifest.xml.in" -Raw
    $manifest = $manifest.
        Replace("{{IDENTITY_NAME}}", (Escape-Xml $IdentityName)).
        Replace("{{PUBLISHER}}", (Escape-Xml $Publisher)).
        Replace("{{PUBLISHER_DISPLAY_NAME}}", (Escape-Xml $PublisherDisplayName)).
        Replace("{{PRODUCT_DISPLAY_NAME}}", (Escape-Xml $ProductDisplayName)).
        Replace("{{VERSION}}", $resolvedPackageVersion)
    $manifestPath = Join-Path $layout "AppxManifest.xml"
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding utf8 -NoNewline

    [xml]$manifestDocument = Get-Content -LiteralPath $manifestPath -Raw
    $manager = [Xml.XmlNamespaceManager]::new($manifestDocument.NameTable)
    $manager.AddNamespace("f", "http://schemas.microsoft.com/appx/manifest/foundation/windows10")
    $manager.AddNamespace("d", "http://schemas.microsoft.com/appx/manifest/desktop/windows10")
    $identity = $manifestDocument.SelectSingleNode("/f:Package/f:Identity", $manager)
    $startup = $manifestDocument.SelectSingleNode(
        "/f:Package/f:Applications/f:Application/f:Extensions/d:Extension/d:StartupTask", $manager)
    if (-not $identity -or -not $startup -or $startup.TaskId -ne "MirrorMeStartupTask") {
        throw "Generated manifest is missing the package identity or MirrorMe startup task."
    }
    $manager.AddNamespace("d2", "http://schemas.microsoft.com/appx/manifest/desktop/windows10/2")
    foreach ($firewallExecutable in @("MirrorMe.exe", "sender\MirrorMe.Sender.exe")) {
        $rules = $manifestDocument.SelectNodes(
            "/f:Package/f:Extensions/d2:Extension/d2:FirewallRules[@Executable='$firewallExecutable']/d2:Rule[@Direction='in']",
            $manager)
        $protocols = @($rules | ForEach-Object { $_.IPProtocol }) | Sort-Object -Unique
        if (($protocols -join ",") -ne "TCP,UDP") {
            throw "Generated manifest is missing inbound TCP and UDP firewall rules for $firewallExecutable."
        }
    }

    Invoke-Checked $makeAppx @("pack", "/d", $layout, "/p", $OutputPath, "/o")
    $packageCreated = $true

    if ($CertificatePath) {
        $CertificatePath = (Resolve-Path -LiteralPath $CertificatePath).Path
        $password = [Environment]::GetEnvironmentVariable($CertificatePasswordEnvironmentVariable)
        if (-not $password) {
            throw "Set $CertificatePasswordEnvironmentVariable before signing the package."
        }
        Invoke-Checked $signTool @(
            "sign", "/fd", "SHA256", "/f", $CertificatePath, "/p", $password, $OutputPath)
    }

    Invoke-Checked $makeAppx @("unpack", "/p", $OutputPath, "/d", $verification, "/o")
    $verifiedExecutable = Join-Path $verification "MirrorMe.exe"
    $verifiedSenderExecutable = Join-Path $verification "sender\MirrorMe.Sender.exe"
    if (-not (Test-Path -LiteralPath (Join-Path $verification "AppxManifest.xml")) -or
        -not (Test-Path -LiteralPath $verifiedExecutable) -or
        -not (Test-Path -LiteralPath $verifiedSenderExecutable)) {
        throw "MSIX verification did not recover the manifest and required executables."
    }
    $expectedLicenseFiles = @(Get-ChildItem -LiteralPath $licenseSource -Recurse -File -Force)
    if (-not $expectedLicenseFiles.Count) {
        throw "The generated license tree is empty: $licenseSource"
    }
    foreach ($licenseFile in $expectedLicenseFiles) {
        $relativeLicensePath = [IO.Path]::GetRelativePath($licenseSource, $licenseFile.FullName)
        $verifiedLicensePath = Join-Path $verification "licenses\$relativeLicensePath"
        if (-not (Test-Path -LiteralPath $verifiedLicensePath -PathType Leaf)) {
            throw "MSIX is missing license file: $relativeLicensePath"
        }
        $sourceHash = (Get-FileHash -LiteralPath $licenseFile.FullName -Algorithm SHA256).Hash
        $packageHash = (Get-FileHash -LiteralPath $verifiedLicensePath -Algorithm SHA256).Hash
        if ($packageHash -ne $sourceHash) {
            throw "MSIX license file differs from its source: $relativeLicensePath"
        }
    }
    foreach ($requiredText in @(
        "COPYING-GPL-3.0.txt",
        "SOURCE.txt",
        "NATIVE-SOURCE-NOTICES.txt",
        "licenses\COPYING-GPL-3.0.txt",
        "licenses\application\COPYING-GPL-3.0.txt"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $verification $requiredText) -PathType Leaf)) {
            throw "MSIX is missing required license/source notice: $requiredText"
        }
    }
    $gplSourceHash = (Get-FileHash -LiteralPath (Join-Path $root "packaging\msix\COPYING-GPL-3.0.txt") -Algorithm SHA256).Hash
    $gplPackageHash = (Get-FileHash -LiteralPath (Join-Path $verification "COPYING-GPL-3.0.txt") -Algorithm SHA256).Hash
    if ($gplPackageHash -ne $gplSourceHash) {
        throw "The GPLv3 text recovered from the MSIX differs from the checked-in license."
    }
    $verifiedSourceLines = @(Get-Content -LiteralPath (Join-Path $verification "SOURCE.txt"))
    if ($verifiedSourceLines.Count -ne 2 -or
        $verifiedSourceLines[0] -ne "MirrorMe $displayVersion source release:" -or
        $verifiedSourceLines[1] -ne $sourceReleaseUrl) {
        throw "MSIX SOURCE.txt does not identify the exact source tag for $displayVersion."
    }
    $inputExecutableHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    $verifiedExecutableHash = (Get-FileHash -LiteralPath $verifiedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($verifiedExecutableHash -ne $inputExecutableHash) {
        throw "The executable recovered from the MSIX does not match the package input."
    }
    $inputSenderExecutableHash = (Get-FileHash -LiteralPath $senderExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    $verifiedSenderExecutableHash = (Get-FileHash -LiteralPath $verifiedSenderExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($verifiedSenderExecutableHash -ne $inputSenderExecutableHash) {
        throw "The sender executable recovered from the MSIX does not match the package input."
    }
    if ($StoreSubmission) {
        if ($inputExecutableHash -ne [string]$applicationReceipt.applicationSha256 -or
            $inputSenderExecutableHash -ne [string]$applicationReceipt.senderExecutableSha256) {
            throw "Packaged executables no longer match the source-bound application build receipt."
        }
        $sourceTreeChanges = @(Get-SourceTreeChanges)
        if ($sourceTreeChanges.Count) {
            throw "The source tree changed during Store packaging. Rebuild from a clean committed source tree."
        }
        $sourceTreeCleanAtEnd = $true
    }

    $receipt = [ordered]@{
        applicationVersion = $ApplicationVersion
        packageVersion = $resolvedPackageVersion
        identityName = $IdentityName
        publisher = $Publisher
        publisherDisplayName = $PublisherDisplayName
        productDisplayName = $ProductDisplayName
        architecture = "x64"
        minimumWindowsVersion = "10.0.22000.0"
        storeSubmission = [bool]$StoreSubmission
        signed = [bool]$CertificatePath
        package = $OutputPath
        packageSha256 = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        executableSha256 = $inputExecutableHash
        senderExecutableSha256 = $inputSenderExecutableHash
        sourceCommit = $sourceCommit
        sourceTreeClean = $sourceTreeCleanAtEnd
        sourceTag = $sourceTag
        sourceReleaseUrl = $sourceReleaseUrl
        sourceReleaseVerified = $sourceReleaseVerified
        licenseFileCount = $expectedLicenseFiles.Count
        distributionApproved = [bool](
            $StoreSubmission -and $sourceReleaseVerified -and $nativeProvenanceVerified -and
            $applicationReceiptVerified -and $sourceTreeCleanAtEnd
        )
        startupTaskId = "MirrorMeStartupTask"
        verifiedByUnpack = $true
    }
    $receiptPath = "$OutputPath.json"
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    if ($receipt.distributionApproved) {
        $applicationReceipt = Get-Content -LiteralPath $applicationReceiptPath -Raw | ConvertFrom-Json
        $applicationReceipt.distributionApproved = $true
        $applicationReceipt | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $applicationReceiptPath -Encoding utf8
        # The checked-in file stays false; only this build's generated copy records readiness.
        $generatedDependencies = Get-Content -LiteralPath $generatedDependenciesPath -Raw | ConvertFrom-Json
        $generatedDependencies.distribution.ready = $true
        $generatedDependencies | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $generatedDependenciesPath -Encoding utf8
        $storeApproved = $true
    }
    Write-Host "MSIX package: $OutputPath"
    Write-Host "SHA-256: $($receipt.packageSha256)"
    Write-Host "Receipt: $receiptPath"
    if (-not $StoreSubmission) {
        Write-Warning "This package uses a development identity. Use -StoreSubmission with Partner Center identity values before uploading."
    }
} finally {
    # A Store package that failed any later check must not survive looking approved.
    if ($StoreSubmission -and $packageCreated -and -not $storeApproved) {
        Remove-Item -LiteralPath $OutputPath, "$OutputPath.json" -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
