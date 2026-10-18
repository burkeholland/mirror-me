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
    $config = Get-Content -LiteralPath "wails.json" -Raw | ConvertFrom-Json
    if (-not $ApplicationVersion) {
        $ApplicationVersion = [string]$config.info.productVersion
    }
    if ($ApplicationVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Application version must use major.minor.patch format."
    }
    $resolvedPackageVersion = Convert-ToPackageVersion $ApplicationVersion $PackageVersion
    $displayVersion = $ApplicationVersion

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
        & (Join-Path $PSScriptRoot "build-app.ps1")
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
    }
    foreach ($directory in @($layout, $verification)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $layout "Assets") -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null

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
    foreach ($relativePath in @(
        "LICENSE",
        "PRIVACY.md",
        "THIRD-PARTY-NOTICES.md",
        "native\AUDIO-NOTICES.txt",
        "native\NATIVE-SOURCE-NOTICES.txt",
        "packaging\msix\SOURCE.txt"
    )) {
        Copy-Item -LiteralPath (Join-Path $root $relativePath) -Destination $layout
    }

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
        startupTaskId = "MirrorMeStartupTask"
        verifiedByUnpack = $true
    }
    $receiptPath = "$OutputPath.json"
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding utf8
    Write-Host "MSIX package: $OutputPath"
    Write-Host "SHA-256: $($receipt.packageSha256)"
    Write-Host "Receipt: $receiptPath"
    if (-not $StoreSubmission) {
        Write-Warning "This package uses a development identity. Use -StoreSubmission with Partner Center identity values before uploading."
    }
} finally {
    Pop-Location
}
