[CmdletBinding()]
param([string]$Remote = "origin")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $changes = & git status --porcelain -- site
    if ($LASTEXITCODE -ne 0 -or $changes) { throw "Commit the website changes before publishing." }
    $revision = & git subtree split --prefix=site --quiet HEAD
    if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
        throw "Could not prepare the committed website subtree."
    }
    & git push $Remote "${revision}:refs/heads/gh-pages"
    if ($LASTEXITCODE -ne 0) { throw "Website push failed; the remote branch was not overwritten." }
    Write-Host "Website source published. GitHub Pages will deploy the gh-pages branch."
} finally {
    Pop-Location
}
