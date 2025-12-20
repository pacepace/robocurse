#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Signs the Robocurse monolith with a code signing certificate.

.DESCRIPTION
    Creates a self-signed code signing certificate (if needed), installs it
    to the Trusted Publishers store, and signs Robocurse.ps1.

.PARAMETER ScriptPath
    Path to the script to sign. Defaults to dist\Robocurse.ps1.

.PARAMETER CertSubject
    Subject name for the certificate. Defaults to "Robocurse Signing".

.PARAMETER Force
    Create a new certificate even if one already exists.

.EXAMPLE
    .\Sign-Robocurse.ps1

.EXAMPLE
    .\Sign-Robocurse.ps1 -ScriptPath C:\Deploy\Robocurse.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$ScriptPath,
    [string]$CertSubject = "Robocurse Signing",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Default to Robocurse.ps1 in current directory
if (-not $ScriptPath) {
    $ScriptPath = Join-Path (Get-Location) "Robocurse.ps1"
}

if (-not (Test-Path $ScriptPath)) {
    throw "Script not found: $ScriptPath"
}

$certName = "CN=$CertSubject"

# Check for existing cert
$existingCert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $certName -and $_.NotAfter -gt (Get-Date) }

if ($existingCert -and -not $Force) {
    Write-Host "Using existing certificate: $($existingCert.Thumbprint)" -ForegroundColor Cyan
    $cert = $existingCert | Select-Object -First 1
} else {
    Write-Host "Creating new self-signed code signing certificate..." -ForegroundColor Cyan

    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject $certName `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048

    Write-Host "Created certificate: $($cert.Thumbprint)" -ForegroundColor Green
}

# Check if cert is already trusted
$trusted = Get-ChildItem Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $cert.Thumbprint }

$tempCert = Join-Path $env:TEMP "RobocurseSigning_$($cert.Thumbprint.Substring(0,8)).cer"

try {
    Export-Certificate -Cert $cert -FilePath $tempCert | Out-Null

    # Add to Trusted Root CAs (self-signed cert is its own root)
    $trustedRoot = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint }

    if (-not $trustedRoot) {
        Write-Host "Adding certificate to Trusted Root CAs..." -ForegroundColor Cyan
        $result = & certutil -f -addstore Root $tempCert 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "certutil failed (Root): $result"
        }
        Write-Host "Certificate added to Trusted Root CAs" -ForegroundColor Green
    } else {
        Write-Host "Certificate already in Trusted Root CAs" -ForegroundColor Cyan
    }

    # Add to Trusted Publishers
    if (-not $trusted) {
        Write-Host "Adding certificate to Trusted Publishers..." -ForegroundColor Cyan
        $result = & certutil -f -addstore TrustedPublisher $tempCert 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "certutil failed (TrustedPublisher): $result"
        }
        Write-Host "Certificate added to Trusted Publishers" -ForegroundColor Green
    } else {
        Write-Host "Certificate already in Trusted Publishers" -ForegroundColor Cyan
    }
} finally {
    if (Test-Path $tempCert) {
        Remove-Item $tempCert -Force
    }
}

# Sign the script
Write-Host "Signing $ScriptPath..." -ForegroundColor Cyan

$signParams = @{
    FilePath = $ScriptPath
    Certificate = $cert
    TimestampServer = "http://timestamp.digicert.com"
    HashAlgorithm = "SHA256"
}

$signature = Set-AuthenticodeSignature @signParams

if ($signature.Status -eq 'Valid') {
    Write-Host "`nScript signed successfully!" -ForegroundColor Green
    Write-Host "  Status: $($signature.Status)"
    Write-Host "  Signer: $($signature.SignerCertificate.Subject)"
    Write-Host "  Expires: $($signature.SignerCertificate.NotAfter)"
} else {
    throw "Signing failed: $($signature.Status) - $($signature.StatusMessage)"
}

# Verify
Write-Host "`nVerifying signature..." -ForegroundColor Cyan
$verify = Get-AuthenticodeSignature $ScriptPath

if ($verify.Status -eq 'Valid') {
    Write-Host "Verification passed" -ForegroundColor Green
} else {
    Write-Warning "Verification returned: $($verify.Status)"
}
