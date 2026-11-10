#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_ARCH -ne 'X64') {
    throw 'This bootstrap is only for GitHub-hosted Windows x64 runners.'
}
$runtime = (Get-Content -LiteralPath 'native\source-dependencies.json' -Raw | ConvertFrom-Json).compilerRuntime
$root = Join-Path $env:RUNNER_TEMP 'toolchain'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$archive = Join-Path $root $runtime.vendorFile
Invoke-WebRequest -Uri $runtime.vendorUrl -OutFile $archive
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $runtime.vendorSha256) { throw "Compiler archive hash mismatch: $hash" }
& 7z x $archive "-o$root" -y | Select-Object -Last 1
if ($LASTEXITCODE) { throw '7z could not extract the compiler.' }
Remove-Item -LiteralPath $archive
$bin = Join-Path $root 'mingw64\bin'
Copy-Item -LiteralPath (Join-Path $bin 'mingw32-make.exe') -Destination (Join-Path $bin 'gmake.exe')
Add-Content -LiteralPath $env:GITHUB_ENV -Value "MM_TOOLCHAIN=$bin"
& (Join-Path $bin 'gcc.exe') --version | Select-Object -First 1
if ($LASTEXITCODE) { throw 'Could not run the compiler.' }
& go install github.com/wailsapp/wails/v2/cmd/wails@v2.15.0
if ($LASTEXITCODE) { throw 'Could not install Wails.' }
& npm --prefix frontend ci --no-audit --no-fund
if ($LASTEXITCODE) { throw 'Could not install the locked frontend packages.' }
