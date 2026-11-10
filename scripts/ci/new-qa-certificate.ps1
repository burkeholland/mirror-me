#Requires -Version 7.2
param([Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$certificate = New-SelfSignedCertificate -Type Custom -Subject 'CN=Burke Holland' -KeyUsage DigitalSignature `
    -FriendlyName 'MirrorMe QA throwaway' -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(30) `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
Write-Host "::add-mask::$password"
$pfx = Join-Path $env:RUNNER_TEMP 'qa-signing.pfx'
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password $securePassword | Out-Null
Export-Certificate -Cert $certificate -FilePath (Join-Path $OutputDirectory 'MirrorMe-QA.cer') | Out-Null
Add-Content -LiteralPath $env:GITHUB_ENV -Value "MIRRORME_MSIX_CERT_PASSWORD=$password"
Add-Content -LiteralPath $env:GITHUB_ENV -Value "MM_QA_PFX=$pfx"
Write-Host "Throwaway QA certificate expires $($certificate.NotAfter.ToString('yyyy-MM-dd')). The private key is not an artifact."
