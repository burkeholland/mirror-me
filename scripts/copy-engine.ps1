<#
.SYNOPSIS
    Copies the bundled UxPlay engine next to a freshly built MirrorMe.exe.

.DESCRIPTION
    `wails build` only compiles the Go/webview binary - it has no built-in
    way to also stage extra runtime assets, and the engine/ directory is far
    too large (~250MB of exes/DLLs) to embed with go:embed. Instead this
    script is wired up as a Wails "postBuildHooks" entry (see wails.json)
    and copies engine/ from the project root into build/bin/engine so the
    app's own engine-locator (see locateEngine in engine.go) finds it next
    to the executable, exactly like it would next to an installed app.

    Wails runs post-build hooks with the working directory already set to
    the output bin directory (build/bin), so this script derives the
    project root from its own current directory rather than assuming an
    absolute path - that keeps it correct no matter where the repo is
    cloned or what build:dir is configured.

    Only copies files that are new or changed (via Robocopy /XO), so
    repeated local builds stay fast instead of re-copying ~250MB every time.
#>

$ErrorActionPreference = 'Stop'

$binDir = $PWD.Path
$projectRoot = Split-Path $PSScriptRoot -Parent
$source = Join-Path $projectRoot 'engine'
$destination = Join-Path $binDir 'engine'

if (-not (Test-Path -LiteralPath (Join-Path $source 'mirrorme-receiver.exe'))) {
    Write-Error "The background receiver is missing. Run scripts\build-receiver.ps1 before packaging MirrorMe."
    exit 1
}

# The old Qt desktop wrapper is not part of MirrorMe's runtime.
$excluded = @('uxplay-windows.exe', 'uxplay-bluetooth-beacon.exe', 'compile_commands.json')

# Robocopy exit codes 0-7 are all "success" (bit flags for copied/skipped
# files); only 8+ indicates a real failure.
robocopy $source $destination /E /XO /XF $excluded /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Error "robocopy failed while copying the engine folder (exit code $LASTEXITCODE)."
    exit 1
}

foreach ($name in $excluded) {
    $oldFile = Join-Path $destination $name
    if (Test-Path -LiteralPath $oldFile) {
        Remove-Item -LiteralPath $oldFile -Force
    }
}

foreach ($name in @('LICENSE', 'THIRD-PARTY-NOTICES.md', 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $binDir -Force
}

Write-Host "Engine folder staged at '$destination'."
exit 0
