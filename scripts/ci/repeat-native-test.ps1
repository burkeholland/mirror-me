#Requires -Version 7.2
param(
    [string]$Test = 'protocol_receive_bounds',
    [ValidateRange(1, 100)][int]$Runs = 20
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$binary = (Resolve-Path 'build\native\cmake').Path
$exe = (Resolve-Path "build\native\tests\$Test.exe").Path
$ctest = (Get-Command ctest -ErrorAction Stop).Source
$scratch = Join-Path $env:RUNNER_TEMP 'repeat-test'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

function Add-Count($Table, [string]$Key) {
    if (-not $Table.ContainsKey($Key)) { $Table[$Key] = 0 }
    $Table[$Key]++
}
function Format-Counts($Table) {
    ($Table.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '
}
function Invoke-Table([string]$Label) {
    $file = @{}; $pipe = @{}; $viaCtest = @{}
    for ($i = 0; $i -lt $Runs; $i++) {
        $p = Start-Process -FilePath $exe -WorkingDirectory $binary -NoNewWindow -PassThru `
            -RedirectStandardOutput (Join-Path $scratch 'o.txt') -RedirectStandardError (Join-Path $scratch 'e.txt')
        try {
            if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw 'Native test timed out.' }
            Add-Count $file ('0x{0:X}' -f $p.ExitCode)
        } finally { $p.Dispose() }
    }
    for ($i = 0; $i -lt $Runs; $i++) {
        $info = [Diagnostics.ProcessStartInfo]::new($exe)
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.UseShellExecute = $false
        $info.WorkingDirectory = $binary
        $q = [Diagnostics.Process]::Start($info)
        try {
            $errors = $q.StandardError.ReadToEndAsync()
            $output = $q.StandardOutput.ReadToEndAsync()
            if (-not $q.WaitForExit(60000)) { Stop-Process -Id $q.Id -Force; throw 'Native test timed out.' }
            $null = $errors.GetAwaiter().GetResult()
            $null = $output.GetAwaiter().GetResult()
            Add-Count $pipe ('0x{0:X}' -f $q.ExitCode)
        } finally { $q.Dispose() }
    }
    for ($i = 0; $i -lt $Runs; $i++) {
        $null = & $ctest --test-dir $binary -R "^$Test`$" --timeout 60 2>&1
        if ($LASTEXITCODE -eq 0) { Add-Count $viaCtest 'pass' } else { Add-Count $viaCtest 'fail' }
    }
    $row = "| $Label | $(Format-Counts $file) | $(Format-Counts $pipe) | $(Format-Counts $viaCtest) |"
    Write-Host $row
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $row
    return @($file.Keys + $pipe.Keys | Where-Object { $_ -ne '0x0' }).Count +
        @($viaCtest.Keys | Where-Object { $_ -ne 'pass' }).Count
}
Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @"
### Native receive bounds repeatability ($Runs runs per mode)

| PATH | Direct, stdout to file | Direct, stdout to pipe | ctest |
|---|---|---|---|
"@
$old = $env:PATH
try {
    $bad = Invoke-Table 'Default'
    $env:PATH = "$env:MM_TOOLCHAIN;$old"
    $bad += Invoke-Table 'Toolchain'
    if ($bad) { throw 'Native receive bounds test did not pass every run.' }
} finally { $env:PATH = $old }
