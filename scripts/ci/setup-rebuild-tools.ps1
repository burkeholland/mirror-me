#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Recipe tool installation is only for the disposable hosted runner.'
}
$bash = 'C:\msys64\usr\bin\bash.exe'
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$cache = Join-Path $env:RUNNER_TEMP 'recipe-tool-packages'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$unixCache = (& $bash -lc "cygpath -u '$cache'").Trim()
if ($LASTEXITCODE) { throw 'Could not resolve the recipe tool cache.' }
# Use the image's existing repository snapshot, not a rolling update.
& $bash -lc "pacman -Sw --needed --noconfirm --cachedir '$unixCache' base-devel mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-autotools mingw-w64-ucrt-x86_64-cython"
if ($LASTEXITCODE) { throw 'Could not download the recipe tools from the hosted image snapshot.' }
$packages = @(Get-ChildItem -LiteralPath $cache -File | Where-Object { $_.Name -match '\.pkg\.tar\.(zst|xz)$' })
$cutoff = [DateTimeOffset]::UtcNow.AddDays(-7).ToUnixTimeSeconds()
$records = foreach ($package in $packages) {
    $info = @(& tar -xOf $package.FullName .PKGINFO)
    if ($LASTEXITCODE) { throw 'Could not inspect a recipe tool package.' }
    $date = @($info | Where-Object { $_ -match '^builddate = ' })
    if ($date.Count -ne 1 -or [long]($date[0] -split ' = ', 2)[1] -gt $cutoff) {
        throw "Recipe tool package is not verifiably at least seven days old: $($package.Name)"
    }
    [ordered]@{
        file = $package.Name
        sha256 = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        buildDate = ($date[0] -split ' = ', 2)[1]
    }
}
@($records) | ConvertTo-Json | Set-Content -LiteralPath "$env:RUNNER_TEMP\recipe-tool-record.json"
if ($packages.Count) {
    $archives = ($packages | ForEach-Object { "'$unixCache/$($_.Name)'" }) -join ' '
    & $bash -lc "pacman -U --noconfirm $archives"
    if ($LASTEXITCODE) { throw 'Could not install the verified recipe tools.' }
}
& $bash -lc 'command -v makepkg-mingw gcc autoconf automake perl pkg-config; gcc --version | head -1'
if ($LASTEXITCODE) { throw 'Recipe toolchain is incomplete.' }
