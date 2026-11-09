#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ApplicationVersion,
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceCommit = '',
    [string]$ReferenceSourceZip = '',
    [string]$ReferenceSourceTag = 'v0.2.4-preview.1',
    [string]$ReferenceSourceSha256 = '4fab1d0a86111ecefef0a53767bb931d147da2191846334e02aefcd1bcf38b8a',
    [string]$OutputPath = '',
    [switch]$Force
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

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required source input is missing: $Path"
    }
    $actual = Get-Hash $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "SHA-256 mismatch for $Path; expected $Expected, got $actual."
    }
}

function Write-Json([string]$Path, [object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required source directory is missing: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($entry in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $Destination -Recurse -Force
    }
}

function Copy-ZipEntry(
    [IO.Compression.ZipArchiveEntry]$Entry,
    [string]$Destination,
    [string]$RelativePath = ''
) {
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    if (-not $RelativePath) { $RelativePath = $Entry.FullName }
    $relative = $RelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)') {
        throw "Reference archive contains an unsafe path: $($Entry.FullName)"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
    if (-not $path.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Reference archive path escaped its destination: $($Entry.FullName)"
    }
    if ($Entry.FullName.EndsWith('/')) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $input = $Entry.Open()
    try {
        $output = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose() }
    } finally { $input.Dispose() }
}

function Import-ReferenceNativeSources(
    [string]$ArchivePath,
    [string]$ExpectedArchiveHash,
    [string]$NativeDestination,
    [string]$ProtocolBundleDestination
) {
    Assert-Hash $ArchivePath $ExpectedArchiveHash
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $prefix = 'MirrorMe-source/native-sources/'
        $entries = @($archive.Entries | Where-Object { $_.FullName.StartsWith($prefix, [StringComparison]::Ordinal) })
        if (-not $entries.Count) {
            throw 'Reference source ZIP does not contain the expected native-sources tree.'
        }
        foreach ($entry in $entries) {
            $relative = $entry.FullName.Substring($prefix.Length)
            if ($relative) {
                $entryPath = [IO.Path]::GetFullPath((Join-Path $NativeDestination $relative.Replace('/', '\')))
                $destinationRoot = [IO.Path]::GetFullPath($NativeDestination).TrimEnd('\') + '\'
                if (-not $entryPath.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Reference archive path escaped its destination: $($entry.FullName)"
                }
                Copy-ZipEntry $entry $NativeDestination $relative
            }
        }
        $bundleEntry = $archive.GetEntry('MirrorMe-source/protocol.git.bundle')
        if (-not $bundleEntry) {
            throw 'Reference source ZIP does not contain protocol.git.bundle.'
        }
        Copy-ZipEntry $bundleEntry (Split-Path -Parent $ProtocolBundleDestination) 'protocol.git.bundle'
    } finally {
        $archive.Dispose()
    }
}

function Get-ReferenceApplicationCommit([string]$ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry('MirrorMe-source/build-receipt.json')
        if (-not $entry) { throw 'Reference source ZIP is missing its build receipt.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try {
            $receipt = $reader.ReadToEnd() | ConvertFrom-Json
            return [string]$receipt.sourceCommit
        } finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }
}

function ConvertTo-GoEscape([string]$Value) {
    return [regex]::Replace(
        $Value,
        '[A-Z]',
        [Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return '!' + $match.Value.ToLowerInvariant()
        }
    )
}

function Test-SourceTextFile([string]$Path) {
    $textExtensions = @(
        '.asc', '.c', '.cc', '.cmake', '.cpp', '.cs', '.csproj', '.css', '.go', '.h', '.html',
        '.hpp', '.ini', '.js', '.json', '.key', '.lock', '.md', '.mjs', '.mod', '.patch',
        '.pem', '.props', '.ps1', '.py', '.rst', '.sh', '.sum', '.text', '.toml',
        '.txt', '.xml', '.yaml', '.yml'
    )
    $textNames = @(
        '.editorconfig', '.gitattributes', '.gitignore', 'AUTHORS', 'COPYING',
        'Dockerfile', 'LICENSE', 'Makefile', 'NOTICE', 'PATENTS', 'README',
        'THIRD-PARTY-NOTICES', 'go.mod', 'go.sum'
    )
    $name = [IO.Path]::GetFileName($Path)
    return [IO.Path]::GetExtension($name) -in $textExtensions -or $name -in $textNames
}

function Test-KnownOpenSslTestPrivateKeyFixture([string]$Path) {
    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '(?i)(?:^|/)openssl-3\.6\.1/(?:apps|demos|test|fuzz)/') {
        # The hash-pinned OpenSSL source includes published private-key fixtures for its tests and examples.
        return $true
    }
    # Go module zips escape uppercase letters as !lowercase.
    $normalizedPaths = @(
        $normalized,
        [regex]::Replace(
            $normalized,
            '[A-Z]',
            [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return '!' + $match.Value.ToLowerInvariant()
            }
        ),
        [regex]::Replace(
            $normalized,
            '!([a-z])',
            [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups[1].Value.ToUpperInvariant()
            }
        )
    )
    # These are upstream test vectors, not application or distribution signing keys.
    $knownPaths = @(
        'src/crypto/crypto_test.go',
        'src/crypto/internal/fips140only/fips140only_test.go',
        'src/crypto/rsa/example_test.go',
        'src/crypto/rsa/rsa_test.go',
        'src/crypto/tls/certificates_test.go',
        'src/crypto/tls/example_test.go',
        'src/crypto/tls/testdata/example-key.pem',
        'src/crypto/tls/tls_test.go',
        'src/crypto/x509/pem_decrypt_test.go',
        'src/crypto/x509/platform_root_key.pem',
        'src/crypto/x509/x509_test.go',
        'src/crypto/x509/x509_test_import.go',
        'src/encoding/pem/pem_test.go',
        'src/net/http/internal/testcert/testcert.go',
        'src/net/smtp/smtp_test.go',
        'github.com/cloudflare/circl@v1.6.3/blindsign/blindrsa/testdata/testRSA2048.rfc9500.pem',
        'github.com/go-git/go-git/v5@v5.19.2/plumbing/transport/http/testdata/certs/server.key',
        'github.com/go-git/go-git/v5@v5.19.2/worktree_commit_test.go',
        'github.com/labstack/echo/v4@v4.13.3/_fixture/certs/key.pem',
        'github.com/ProtonMail/go-crypto@v1.1.6/openpgp/clearsign/clearsign_test.go',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/integration_tests/testdata/test_vectors.json',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/integration_tests/v2/testdata/test_vectors.json',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/clearsign/clearsign_test.go',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/keys_test_data.go',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/read_write_test_data.go',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/test_data/aead-ocb-asym-key.asc',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/v2/keys_test_data.go',
        'github.com/!proton!mail/go-crypto@v1.1.6/openpgp/v2/read_write_test_data.go',
        'golang.org/x/crypto@v0.53.0/acme/jws_test.go',
        'golang.org/x/crypto@v0.53.0/openpgp/clearsign/clearsign_test.go',
        'golang.org/x/crypto@v0.53.0/openpgp/read_test.go',
        'golang.org/x/crypto@v0.53.0/ssh/keys_test.go',
        'golang.org/x/crypto@v0.53.0/ssh/testdata/keys.go',
        'golang.org/x/crypto@v0.53.0/ssh/test/session_test.go',
        'golang.org/x/net@v0.56.0/internal/quic/cmd/interop/main_test.go',
        'golang.org/x/net@v0.56.0/internal/testcert/testcert.go'
    )
    foreach ($normalizedPath in $normalizedPaths) {
        foreach ($knownPath in $knownPaths) {
            if ($normalizedPath.Equals($knownPath, [StringComparison]::OrdinalIgnoreCase) -or
                $normalizedPath.EndsWith("/$knownPath", [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Assert-SourceFileNameSafe([string]$Name, [string]$Path = '') {
    $isKnownTestKey = Test-KnownOpenSslTestPrivateKeyFixture $Path
    if (($Name -match '(?i)(^|\.)(pfx|p12|p7b|snk|keystore|key)$' -or
            $Name -match '^(?i:id_rsa|id_ed25519|id_ecdsa)$') -and -not $isKnownTestKey) {
        throw "Source release contains a possible signing key: $Path"
    }
}

function Assert-SourceTextSafe([string]$Text, [string]$Name) {
    $scanText = $Text
    $normalizedName = $Name.Replace('\', '/')
    if ($normalizedName.EndsWith(
            '/ffmpeg-8.0.1/libavformat/tls_openssl.c',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        # This pinned FFmpeg comment shows an ellipsis-only PEM example, not key bytes.
        $scanText = [regex]::Replace(
            $scanText,
            '-----BEGIN PRIVATE KEY-----\\n\u2026\\n-----END PRIVATE KEY-----\\n',
            ''
        )
    }
    $pathPatterns = [Collections.Generic.List[string]]::new()
    foreach ($profileRoot in @($env:USERPROFILE, $env:HOME) | Where-Object { $_ }) {
        $normalizedRoot = $profileRoot.TrimEnd([char[]]@([char]92, [char]47))
        if (-not $normalizedRoot) { continue }
        $pathPatterns.Add('(?i)' + [regex]::Escape($normalizedRoot) + '[\\/]')
        $forwardRoot = $normalizedRoot.Replace('\', '/')
        if ($forwardRoot -ne $normalizedRoot) {
            $pathPatterns.Add('(?i)' + [regex]::Escape($forwardRoot) + '[\\/]')
        }
    }
    if ($env:USERNAME) {
        $pathPatterns.Add(
            '(?i)(?:^|[\s"''=])/(?:Users|home)/' + [regex]::Escape($env:USERNAME) + '/'
        )
    }
    $isKnownTestKey = Test-KnownOpenSslTestPrivateKeyFixture $Name
    $keyPatterns = @(
        '-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----',
        '-----BEGIN RSA TESTING KEY-----'
    )
    if (-not $isKnownTestKey) {
        foreach ($pattern in $keyPatterns) {
            if ([regex]::IsMatch($scanText, $pattern)) {
                throw "Source release contains a possible credential or private key in $Name."
            }
        }
    }
    $secretPatterns = @(
        '(?i)\b(?:ghp|gho|ghs|ghu|github_pat)_[A-Za-z0-9_]{20,}\b',
        '\bAKIA[0-9A-Z]{16}\b',
        '(?i)\bsk-[A-Za-z0-9]{24,}\b'
    )
    foreach ($pattern in $pathPatterns) {
        if ([regex]::IsMatch($scanText, $pattern)) {
            throw "Source release contains a developer-local path in $Name."
        }
    }
    foreach ($pattern in $secretPatterns) {
        if ([regex]::IsMatch($scanText, $pattern)) {
            throw "Source release contains a possible credential or private key in $Name."
        }
    }
}

function Assert-ArchiveEntryPath([string]$RelativePath, [string]$ArchivePath) {
    $normalized = $RelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($normalized) -or
        $normalized -match '(^|\\)\.\.(\\|$)' -or
        $normalized -match '^[A-Za-z]:') {
        throw "Source archive contains an unsafe path in ${ArchivePath}: $RelativePath"
    }
}

function Assert-SourceTreeSafe([string]$Path) {
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) {
        Assert-SourceFileNameSafe $file.Name $file.FullName
        if (-not (Test-SourceTextFile $file.FullName)) { continue }
        Assert-SourceTextSafe ([IO.File]::ReadAllText($file.FullName)) $file.FullName
    }
}

function Assert-ZipSourceSafe([string]$ArchivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            Assert-ArchiveEntryPath $entry.FullName $ArchivePath
            if (-not $entry.Name) { continue }
            Assert-SourceFileNameSafe $entry.Name $entry.FullName
            if (-not (Test-SourceTextFile $entry.FullName)) { continue }
            $stream = $entry.Open()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
            try {
                $text = $reader.ReadToEnd()
                Assert-SourceTextSafe $text $entry.FullName
            }
            finally { $reader.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Assert-TarSourceSafe([string]$ArchivePath, [string]$WorkingRoot) {
    $verboseEntries = @(& tar -tvf $ArchivePath)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect source archive: $ArchivePath" }
    foreach ($entry in $verboseEntries) {
        $line = [string]$entry
        if ($line.Length -and $line[0] -notin @('-', 'd')) {
            throw "Source archive contains a link or special file that cannot be scanned safely: $ArchivePath"
        }
    }
    $entries = @(& tar -tf $ArchivePath)
    if ($LASTEXITCODE -ne 0) { throw "Could not list source archive: $ArchivePath" }
    foreach ($entry in $entries) {
        Assert-ArchiveEntryPath ([string]$entry) $ArchivePath
    }
    $scanRoot = Join-Path $WorkingRoot ("archive-scan-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $scanRoot | Out-Null
    try {
        Invoke-Checked 'tar' @('-xf', $ArchivePath, '-C', $scanRoot)
        Assert-SourceTreeSafe $scanRoot
    } catch {
        throw "Source archive failed its safety scan ($ArchivePath): $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $scanRoot -Recurse -Force
    }
}

function Assert-NestedSourceArchivesSafe([string]$Path, [string]$WorkingRoot) {
    $archives = Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Where-Object {
            $_.Extension -in @('.zip', '.nupkg') -or
            $_.Name -match '(?i)\.(?:tar|tar\.(?:gz|xz|bz2|zst)|tgz|tbz2?)$'
        }
    foreach ($archive in $archives) {
        if ($archive.Extension -in @('.zip', '.nupkg')) {
            Assert-ZipSourceSafe $archive.FullName
        } else {
            Assert-TarSourceSafe $archive.FullName $WorkingRoot
        }
    }
}

function Assert-Inventory([string]$Directory, [string]$InventoryPath) {
    if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
        throw "Source file inventory is missing: $InventoryPath"
    }
    $inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
    foreach ($item in $inventory) {
        $relative = [string]$item.path
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Source inventory contains an unsafe path: $relative"
        }
        $file = [IO.Path]::GetFullPath((Join-Path $Directory $relative.Replace('/', '\')))
        $directoryRoot = [IO.Path]::GetFullPath($Directory).TrimEnd('\') + '\'
        if (-not $file.StartsWith($directoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Source inventory path escaped its directory: $relative"
        }
        Assert-Hash $file ([string]$item.sha256)
    }
}

Push-Location $root
$stageRoot = ''
$workingRoot = ''
$appTree = ''
$completed = $false
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue) -or
        -not (Get-Command go -ErrorAction SilentlyContinue) -or
        -not (Get-Command npm -ErrorAction SilentlyContinue) -or
        -not (Get-Command tar -ErrorAction SilentlyContinue)) {
        throw 'Source packaging requires Git, Go, npm, and tar.'
    }
    if (-not $SourceCommit) {
        $SourceCommit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $SourceCommit) {
            throw 'Could not identify the application source commit.'
        }
    }
    $SourceCommit = $SourceCommit.ToLowerInvariant()
    & git cat-file -e "$SourceCommit^{commit}"
    if ($LASTEXITCODE -ne 0) {
        throw "Application source commit is unavailable: $SourceCommit"
    }

    $versionJson = & git show "${SourceCommit}:wails.json"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read wails.json from $SourceCommit."
    }
    $sourceVersion = (($versionJson -join "`n") | ConvertFrom-Json).info.productVersion
    if ([string]$sourceVersion -ne $ApplicationVersion) {
        throw "Requested version $ApplicationVersion does not match source commit version $sourceVersion."
    }
    $sourceTag = "v$ApplicationVersion-preview.1"
    $sourceUrl = "https://github.com/burkeholland/mirror-me/releases/tag/$sourceTag"

    if (-not $OutputPath) {
        $outputDirectory = Join-Path $root "build\source-release\$ApplicationVersion"
        $OutputPath = Join-Path $outputDirectory "MirrorMe-$ApplicationVersion-source.zip"
    } elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path $root $OutputPath
    }
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    if (Test-Path -LiteralPath $OutputPath) {
        if (-not $Force) {
            throw "Source archive already exists: $OutputPath. Use -Force to regenerate it."
        }
        Remove-Item -LiteralPath $OutputPath -Force
    }
    foreach ($artifact in @(
        (Join-Path $outputDirectory 'release-manifest.json'),
        (Join-Path $outputDirectory 'SHA256SUMS.txt')
    )) {
        if (Test-Path -LiteralPath $artifact) {
            if (-not $Force) {
                throw "Source release metadata already exists: $artifact. Use -Force to regenerate it."
            }
            Remove-Item -LiteralPath $artifact -Force
        }
    }
    $stageRoot = Join-Path $outputDirectory "staging-$ApplicationVersion"
    $workingRoot = Join-Path $outputDirectory "work-$ApplicationVersion"
    foreach ($directory in @($stageRoot, $workingRoot)) {
        if (Test-Path -LiteralPath $directory) {
            if (-not $Force) {
                throw "Source staging directory already exists: $directory. Use -Force to regenerate it."
            }
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
    $packageRoot = Join-Path $stageRoot 'MirrorMe-source'
    $appTree = Join-Path $workingRoot 'application-source'
    New-Item -ItemType Directory -Force -Path $packageRoot, $appTree | Out-Null

    $nativeBuildRoot = Join-Path $root 'build\native-sources'
    $nativeBundle = if ($ReferenceSourceZip) {
        Join-Path $workingRoot 'reference-native-sources'
    } else {
        Join-Path $nativeBuildRoot 'bundle'
    }
    $protocolBundle = if ($ReferenceSourceZip) {
        Join-Path $workingRoot 'protocol.git.bundle'
    } else {
        Join-Path $nativeBuildRoot 'protocol.git.bundle'
    }
    $referenceCommit = ''
    if ($ReferenceSourceZip) {
        if (-not [IO.Path]::IsPathRooted($ReferenceSourceZip)) {
            $ReferenceSourceZip = Join-Path $root $ReferenceSourceZip
        }
        if (-not (Test-Path -LiteralPath $ReferenceSourceZip -PathType Leaf)) {
            throw "Reference source archive is missing: $ReferenceSourceZip"
        }
        Assert-Hash $ReferenceSourceZip $ReferenceSourceSha256
        $referenceCommit = (& git rev-parse "$ReferenceSourceTag^{commit}").Trim()
        if ($LASTEXITCODE -ne 0 -or -not $referenceCommit) {
            throw "Reference source tag is not available locally: $ReferenceSourceTag"
        }
        $changedInputs = @(& git diff --name-only $referenceCommit $SourceCommit -- `
            native receiver go.mod go.sum frontend/package-lock.json `
            scripts/build-native.ps1 scripts/build-audio-codecs.ps1 scripts/collect-native-sources.ps1)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not compare source inputs against the reference source release.'
        }
        if ($changedInputs.Count) {
            throw "Cannot reuse native source inputs; application or dependency inputs changed since ${ReferenceSourceTag}: $($changedInputs -join ', ')"
        }
    }
    if ($ReferenceSourceZip) {
        if (Test-Path -LiteralPath $nativeBundle) {
            throw "Fresh reference source staging directory already exists: $nativeBundle"
        }
        New-Item -ItemType Directory -Force -Path $nativeBundle | Out-Null
        Import-ReferenceNativeSources $ReferenceSourceZip $ReferenceSourceSha256 $nativeBundle $protocolBundle
    } else {
        & (Join-Path $PSScriptRoot 'collect-native-sources.ps1')
        $protocolBundle = Join-Path $nativeBundle 'protocol.git.bundle'
    }
    if (-not (Test-Path -LiteralPath $protocolBundle -PathType Leaf)) {
        throw 'Pinned protocol Git bundle is missing.'
    }

    $nativeReportPath = Join-Path $nativeBundle 'collection-report.json'
    $nativeInventoryPath = Join-Path $nativeBundle 'file-inventory.json'
    Assert-Inventory $nativeBundle $nativeInventoryPath
    $nativeReport = Get-Content -LiteralPath $nativeReportPath -Raw | ConvertFrom-Json
    $pinsPath = Join-Path $root 'native\source-dependencies.json'
    $pinsHash = Get-Hash $pinsPath
    if ($nativeReport.pinManifestSha256 -ne $pinsHash) {
        throw 'Native source bundle does not match native/source-dependencies.json.'
    }
    $isReferenceBundle = [bool]$ReferenceSourceZip
    $nativeSourceCommit = ''
    $nativeCommitProperty = $nativeReport.PSObject.Properties['applicationSourceCommit']
    if ($nativeCommitProperty) { $nativeSourceCommit = [string]$nativeCommitProperty.Value }
    if ($isReferenceBundle -and -not $nativeSourceCommit) {
        $nativeSourceCommit = Get-ReferenceApplicationCommit $ReferenceSourceZip
    }
    if ($isReferenceBundle -and $nativeSourceCommit -ne $referenceCommit) {
        throw "Existing native source bundle is from $nativeSourceCommit, not reference commit $referenceCommit."
    }
    if (-not $isReferenceBundle -and $nativeSourceCommit -ne $SourceCommit) {
        throw "Native source bundle was collected for $nativeSourceCommit, not $SourceCommit."
    }
    if (-not (Test-Path -LiteralPath $protocolBundle -PathType Leaf)) {
        throw 'Pinned protocol Git bundle is missing.'
    }

    $applicationTar = Join-Path $packageRoot 'application-source.tar'
    Invoke-Checked 'git' @('archive', '--format=tar', "--output=$applicationTar", $SourceCommit)
    Invoke-Checked 'tar' @('-xf', $applicationTar, '-C', $appTree)
    $appGoMod = Join-Path $appTree 'go.mod'
    if (-not (Test-Path -LiteralPath $appGoMod -PathType Leaf)) {
        throw 'The frozen application source archive is missing go.mod.'
    }
    $goModText = [IO.File]::ReadAllText($appGoMod)
    $redactions = [Collections.Generic.List[string]]::new()
    $localReplacePattern = '(?m)^// replace github\.com/wailsapp/wails/v2 v2\.15\.0 => [A-Za-z]:\\[^\r\n]*(?:\r?\n|$)'
    if ([regex]::IsMatch($goModText, $localReplacePattern)) {
        $goModText = [regex]::Replace($goModText, $localReplacePattern, '')
        [IO.File]::WriteAllText($appGoMod, $goModText, [Text.UTF8Encoding]::new($false))
        $redactions.Add('Removed one inactive developer-local Go replacement comment from go.mod; build directives and application code are unchanged.')
        Remove-Item -LiteralPath $applicationTar -Force
        Invoke-Checked 'tar' @('-cf', $applicationTar, '-C', $appTree, '.')
    }
    Assert-SourceTreeSafe $appTree
    & tar -tf $applicationTar > $null
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the frozen application source archive.' }

    $protocolVerification = Join-Path $workingRoot 'protocol-verification'
    Invoke-Checked 'git' @('clone', '--quiet', $protocolBundle, $protocolVerification)
    $sourcePinsPath = Join-Path $appTree 'native\source-dependencies.json'
    $sourcePins = Get-Content -LiteralPath $sourcePinsPath -Raw | ConvertFrom-Json
    $protocolCommit = [string]$sourcePins.protocol.commit
    if ($protocolCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "The frozen application source has an invalid protocol commit: $protocolCommit"
    }
    Invoke-Checked 'git' @('-C', $protocolVerification, 'cat-file', '-e', "$protocolCommit^{commit}")
    Invoke-Checked 'git' @('-C', $protocolVerification, 'fsck', '--full')
    Remove-Item -LiteralPath $protocolVerification -Recurse -Force

    $nativeDestination = Join-Path $packageRoot 'native-sources'
    Copy-DirectoryContents $nativeBundle $nativeDestination
    Copy-Item -LiteralPath $protocolBundle -Destination (Join-Path $packageRoot 'protocol.git.bundle')
    Copy-Item -LiteralPath (Join-Path $root 'packaging\source-release\REBUILD.ps1') `
        -Destination (Join-Path $packageRoot 'REBUILD.ps1')
    Copy-Item -LiteralPath (Join-Path $appTree 'LICENSE') -Destination (Join-Path $packageRoot 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $root 'packaging\msix\COPYING-GPL-3.0.txt') `
        -Destination (Join-Path $packageRoot 'COPYING-GPL-3.0.txt')
    Copy-Item -LiteralPath (Join-Path $appTree 'THIRD-PARTY-NOTICES.md') -Destination $packageRoot
    Copy-Item -LiteralPath (Join-Path $root 'native\NATIVE-SOURCE-NOTICES.txt') `
        -Destination (Join-Path $packageRoot 'NATIVE-SOURCE-NOTICES.txt')

    $frontendPackageRoot = Join-Path $packageRoot 'frontend'
    New-Item -ItemType Directory -Force -Path $frontendPackageRoot | Out-Null
    $lucideProvenancePath = Join-Path $root 'frontend\provenance.json'
    $lucide = Get-Content -LiteralPath $lucideProvenancePath -Raw | ConvertFrom-Json
    $packageArchive = Join-Path $frontendPackageRoot "lucide-$($lucide.version).tgz"
    Invoke-Checked 'npm' @('pack', "lucide@$($lucide.version)", '--pack-destination', $frontendPackageRoot, '--silent')
    Assert-Hash $packageArchive ([string]$lucide.packageSha256)
    $lucideSource = Join-Path $frontendPackageRoot "lucide-source-$($lucide.upstreamCommit).tar.gz"
    $lucideSourceUrl = "https://codeload.github.com/lucide-icons/lucide/tar.gz/$($lucide.upstreamCommit)"
    Invoke-WebRequest -Uri $lucideSourceUrl -OutFile $lucideSource
    Assert-Hash $lucideSource ([string]$lucide.upstreamSourceSha256)
    Copy-Item -LiteralPath $lucideProvenancePath -Destination $frontendPackageRoot

    $moduleLines = @()
    Push-Location $appTree
    $previousGoCache = $env:GOMODCACHE
    try {
        Invoke-Checked 'go' @('mod', 'download', 'all')
        Invoke-Checked 'go' @('mod', 'verify')
        $moduleLines = @(& go list -m -f '{{.Path}}|{{.Version}}|{{.Sum}}|{{.GoModSum}}|{{.Dir}}' all)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not enumerate the frozen Go module graph.'
        }
    } finally {
        Pop-Location
        $env:GOMODCACHE = $previousGoCache
    }
    $goCache = (& go env GOMODCACHE).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $goCache) {
        throw 'Could not locate the Go module cache.'
    }
    $moduleSourceRoot = Join-Path $packageRoot 'go-modules\cache\download'
    $moduleInventory = [Collections.Generic.List[object]]::new()
    foreach ($line in $moduleLines) {
        $fields = $line -split '\|', 5
        if ($fields.Count -ne 5 -or -not $fields[1]) { continue }
        $modulePath = $fields[0]
        $moduleVersion = $fields[1]
        if (-not $fields[2] -or -not $fields[3]) {
            throw "Go module checksums are missing for $modulePath@$moduleVersion."
        }
        if (-not $fields[4] -or -not (Test-Path -LiteralPath $fields[4] -PathType Container)) {
            throw "Go module source is unavailable: $modulePath@$moduleVersion."
        }
        $escapedModule = ConvertTo-GoEscape $modulePath
        $escapedVersion = ConvertTo-GoEscape $moduleVersion
        $relative = Join-Path $escapedModule '@v'
        $cacheDirectory = Join-Path $goCache "cache\download\$relative"
        $destinationDirectory = Join-Path $moduleSourceRoot $relative
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
        $moduleFiles = [ordered]@{}
        foreach ($extension in @('.zip', '.mod', '.info', '.ziphash')) {
            $source = Join-Path $cacheDirectory "$escapedVersion$extension"
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Go module download artifact is missing: $modulePath@$moduleVersion ($extension)."
            }
            $destination = Join-Path $destinationDirectory "$escapedVersion$extension"
            Copy-Item -LiteralPath $source -Destination $destination -Force
            $moduleFiles[$extension.TrimStart('.')] = Get-Hash $destination
        }
        $moduleInventory.Add([ordered]@{
            path = $modulePath
            version = $moduleVersion
            sum = $fields[2]
            goModSum = $fields[3]
            files = $moduleFiles
        })
    }
    if (-not $moduleInventory.Count) {
        throw 'The frozen Go module graph did not contain dependency source archives.'
    }
    Write-Json (Join-Path $packageRoot 'go-modules.json') @($moduleInventory.ToArray())

    $goVersionOutput = (& go version).Trim()
    if ($LASTEXITCODE -ne 0 -or $goVersionOutput -notmatch '\b(go[0-9]+(?:\.[0-9]+){1,2})\b') {
        throw 'Could not identify the Go toolchain used to create the source kit.'
    }
    $goVersion = $Matches[1]
    $goRoot = (& go env GOROOT).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $goRoot) {
        throw 'Could not locate the Go runtime source tree.'
    }
    $goSourceArchive = Join-Path $packageRoot "$goVersion.src.tar.gz"
    Invoke-Checked 'tar' @('-czf', $goSourceArchive, '-C', $goRoot, 'src', 'LICENSE', 'PATENTS')

    $senderSourceRoot = Join-Path $appTree 'sender'
    & (Join-Path $PSScriptRoot 'build-sender.ps1') -SourceOnly -SourceRoot $senderSourceRoot
    $senderSource = Join-Path $root 'build\native-sender\source-release'
    if (-not (Test-Path -LiteralPath (Join-Path $senderSource 'WinPlay-source.tar') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $senderSource 'licenses') -PathType Container)) {
        throw 'Sender source archive or dependency licenses were not generated.'
    }
    Copy-DirectoryContents $senderSource (Join-Path $packageRoot 'sender')
    Copy-Item -LiteralPath (Join-Path $senderSourceRoot 'README.md') `
        -Destination (Join-Path $packageRoot 'sender\README.md') -Force
    $senderPackageCount = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'sender\packages') -Filter '*.nupkg' -File).Count
    if (-not $senderPackageCount) {
        throw 'Sender NuGet dependency archives were not retained.'
    }
    $senderScan = Join-Path $workingRoot 'sender-source'
    New-Item -ItemType Directory -Force -Path $senderScan | Out-Null
    $senderArchive = Join-Path $packageRoot 'sender\WinPlay-source.tar'
    Invoke-Checked 'tar' @('-xf', $senderArchive, '-C', $senderScan)
    Assert-SourceTreeSafe $senderScan

    & (Join-Path $PSScriptRoot 'collect-app-licenses.ps1') `
        -ApplicationVersion $ApplicationVersion -Force -UseSourceOnlySender `
        -NativeSourceRoot $nativeBundle -ApplicationSourceRoot $appTree
    $licenseTree = Join-Path $root "build\licenses\$ApplicationVersion"
    if (-not (Test-Path -LiteralPath $licenseTree -PathType Container)) {
        throw "Full application license tree was not generated: $licenseTree"
    }
    Copy-DirectoryContents $licenseTree (Join-Path $packageRoot 'licenses')
    $goModuleArchiveCount = @(Get-ChildItem -LiteralPath $moduleSourceRoot -Filter '*.zip' -Recurse -File).Count
    if ($goModuleArchiveCount -ne $moduleInventory.Count) {
        throw 'The packaged Go source archive count does not match the frozen module graph.'
    }

    $goVersionText = $goVersionOutput
    $reuseManifest = $null
    if ($isReferenceBundle) {
        $reuseManifest = [ordered]@{
            referenceTag = $ReferenceSourceTag
            referenceApplicationCommit = $nativeSourceCommit
            targetApplicationCommit = $SourceCommit
            nativePinManifestSha256 = $pinsHash
            reuseCondition = 'The native, receiver, Go dependency, and frontend lock inputs are unchanged between the reference and target commits.'
        }
        Write-Json (Join-Path $packageRoot 'native-source-reuse.json') $reuseManifest
    }

    $nativeDependencies = Get-Content -LiteralPath (Join-Path $appTree 'native\dependencies.json') -Raw | ConvertFrom-Json
    $senderDependencies = Get-Content -LiteralPath (Join-Path $senderSourceRoot 'dependency.json') -Raw | ConvertFrom-Json
    $sourceManifest = [ordered]@{
        schemaVersion = 1
        applicationVersion = $ApplicationVersion
        sourceTag = $sourceTag
        sourceUrl = $sourceUrl
        sourceCommit = $SourceCommit
        applicationSourceTarSha256 = Get-Hash $applicationTar
        sourceRedactions = @($redactions.ToArray())
        nativeSourceBundleCommit = $nativeSourceCommit
        nativePinManifestSha256 = $pinsHash
        protocolCommit = [string]$nativeDependencies.protocol.commit
        goVersion = $goVersionText
        suppliedGoModuleCount = $moduleInventory.Count
        lucideVersion = [string]$lucide.version
        lucideUpstreamCommit = [string]$lucide.upstreamCommit
        senderSourceCommit = [string]$senderDependencies.commit
        senderPatchSha256 = Get-Hash (Join-Path $senderSourceRoot 'winplay.patch')
        senderWrapperSha256 = Get-Hash (Join-Path $senderSourceRoot 'Program.cs')
        senderNuGetPackageCount = $senderPackageCount
        storeExecutableMatchStatus = 'not verified'
        verification = [ordered]@{
            nativeBundleInventoryVerified = $true
            protocolGitBundleVerified = $true
            GoModuleSourcesDownloadedAndVerified = $true
            licenseTreeGenerated = $true
            sourceSafetyScanPassed = $true
        }
    }
    Write-Json (Join-Path $packageRoot 'source-manifest.json') $sourceManifest

    $readme = @"
MirrorMe $ApplicationVersion source release
==========================================

Application source commit: $SourceCommit
Source tag: $sourceTag
Source release: $sourceUrl

This archive contains the frozen application source, dependency sources,
build inputs, source notices, and rebuild instructions. The application
source is archived from the named commit. Any source-only redactions are
listed in source-manifest.json.

The Store build's MirrorMe.exe match to this source commit was not verified.
No application executable is included in this source archive.

Contents
--------
application-source.tar
  Git source snapshot and its build recipes.
protocol.git.bundle
  Pinned libuxplay Git history required by the native build.
native-sources/
  Pinned native sources, build inputs, recipes, and source correspondence data.
go-modules/ and go-modules.json
  Downloaded source ZIPs and checksum metadata for the frozen Go module graph.
$goVersion.src.tar.gz
  Go runtime and standard library source for $goVersionText.
frontend/
  Locked Lucide package and upstream source with provenance.
sender/
  WinPlay source archive, patch, wrapper, locked NuGet packages, and notices.
licenses/
  Full application, runtime, native, frontend, and sender license texts and notices.
REBUILD.ps1
  Verifies this archive and prepares a local rebuild workspace.

The rebuild requires Windows development tools and internet access for
general-purpose tools and locked build packages. The included sources and
build recipes are provided to support inspection, modification, and rebuilding.
"@
    [IO.File]::WriteAllText((Join-Path $packageRoot 'README.txt'), $readme, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $root 'native\NATIVE-SOURCE-NOTICES.txt') `
        -Destination (Join-Path $packageRoot 'NATIVE-SOURCE-NOTICES.txt') -Force
    $sourceText = "MirrorMe $ApplicationVersion source release:`n$sourceUrl`n"
    [IO.File]::WriteAllText((Join-Path $packageRoot 'SOURCE.txt'), $sourceText, [Text.UTF8Encoding]::new($false))

    Assert-SourceTreeSafe $packageRoot
    Assert-NestedSourceArchivesSafe $packageRoot $workingRoot
    $inventory = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force |
        Where-Object { $_.FullName -ne (Join-Path $packageRoot 'file-inventory.json') } |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{
                path = [IO.Path]::GetRelativePath($packageRoot, $_.FullName).Replace('\', '/')
                bytes = $_.Length
                sha256 = Get-Hash $_.FullName
            }
        })
    Write-Json (Join-Path $packageRoot 'file-inventory.json') $inventory
    Assert-Inventory $packageRoot (Join-Path $packageRoot 'file-inventory.json')

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $OutputPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    $zip = [IO.Compression.ZipFile]::OpenRead($OutputPath)
    try {
        $requiredEntries = @(
            'MirrorMe-source\application-source.tar',
            'MirrorMe-source\native-sources\collection-report.json',
            'MirrorMe-source\protocol.git.bundle',
            'MirrorMe-source\go-modules.json',
            "MirrorMe-source\$goVersion.src.tar.gz",
            "MirrorMe-source\frontend\lucide-$($lucide.version).tgz",
            "MirrorMe-source\frontend\lucide-source-$($lucide.upstreamCommit).tar.gz",
            'MirrorMe-source\frontend\provenance.json',
            'MirrorMe-source\sender\WinPlay-source.tar',
            'MirrorMe-source\sender\winplay.patch',
            'MirrorMe-source\sender\Program.cs',
            'MirrorMe-source\sender\packages.json',
            'MirrorMe-source\sender\README.md',
            'MirrorMe-source\COPYING-GPL-3.0.txt',
            'MirrorMe-source\licenses\file-inventory.json',
            'MirrorMe-source\REBUILD.ps1',
            'MirrorMe-source\source-manifest.json',
            'MirrorMe-source\file-inventory.json'
        )
        $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        foreach ($required in $requiredEntries) {
            if ($required -notin $entryNames) {
                throw "Source archive is missing required content: $required"
            }
        }
    } finally {
        $zip.Dispose()
    }

    $manifestPath = Join-Path $outputDirectory 'release-manifest.json'
    $checksumsPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
    $releaseManifest = [ordered]@{
        schemaVersion = 1
        version = $ApplicationVersion
        tag = $sourceTag
        sourceCommit = $SourceCommit
        sourceUrl = $sourceUrl
        storeBinaryMatchStatus = 'not verified'
        sourceArchive = [ordered]@{
            name = Split-Path -Leaf $OutputPath
            bytes = (Get-Item -LiteralPath $OutputPath).Length
            sha256 = Get-Hash $OutputPath
        }
        verification = [ordered]@{
            sourceArchiveContentsVerified = $true
            sourceTreeSafetyScanPassed = $true
            binarySourceMatchClaimed = $false
        }
    }
    Write-Json $manifestPath $releaseManifest
    $sumLines = @(
        "$(Get-Hash $OutputPath)  $(Split-Path -Leaf $OutputPath)",
        "$(Get-Hash $manifestPath)  release-manifest.json"
    )
    [IO.File]::WriteAllLines($checksumsPath, $sumLines, [Text.UTF8Encoding]::new($false))
    foreach ($line in Get-Content -LiteralPath $checksumsPath) {
        $parts = $line -split '\s{2}', 2
        if ($parts.Count -ne 2) { throw 'Generated checksum list is malformed.' }
        Assert-Hash (Join-Path $outputDirectory $parts[1]) $parts[0]
    }

    Write-Host "Source archive: $OutputPath"
    Write-Host "SHA-256: $($releaseManifest.sourceArchive.sha256)"
    Write-Host "Release manifest: $manifestPath"
    Write-Host "Checksums: $checksumsPath"
} finally {
    if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    if ($workingRoot -and (Test-Path -LiteralPath $workingRoot)) {
        Remove-Item -LiteralPath $workingRoot -Recurse -Force
    }
    Pop-Location
}
