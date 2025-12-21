#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Signs a PowerShell script with a code signing certificate for trusted execution.

.DESCRIPTION
    This script enables running PowerShell scripts under the "AllSigned" execution policy
    by creating and managing a self-signed code signing certificate.

    On first run, it:
    1. Creates a self-signed code signing certificate (valid for 5 years)
    2. Installs it to Trusted Root CAs (so Windows trusts it as a root)
    3. Installs it to Trusted Publishers (so Windows trusts code it signs)
    4. Signs the target script with a SHA256 signature and timestamp

    On subsequent runs, it reuses the existing certificate unless -Force is specified.

    The timestamp from DigiCert ensures signatures remain valid even after the
    certificate expires, as long as the signature was made while the cert was valid.

.PARAMETER ScriptPath
    Path to the script to sign. If not specified, defaults to Robocurse.ps1 in the
    current directory. Accepts a positional argument.

.PARAMETER CertSubject
    Subject name for the certificate. Defaults to "Robocurse Signing".
    Change this if you want separate certificates for different scripts.

.PARAMETER Force
    Create a new certificate even if a valid one already exists.
    Use this if the existing certificate is compromised or you want to rotate keys.

.EXAMPLE
    .\Sign-Robocurse.ps1

    Signs .\Robocurse.ps1 in the current directory using the default certificate.

.EXAMPLE
    .\Sign-Robocurse.ps1 C:\Deploy\Robocurse.ps1

    Signs a script at a specific path (positional argument).

.EXAMPLE
    .\Sign-Robocurse.ps1 -ScriptPath C:\Scripts\MyScript.ps1 -CertSubject "My Company Signing"

    Signs a different script with a custom certificate name.

.EXAMPLE
    .\Sign-Robocurse.ps1 -Force

    Creates a new certificate even if one already exists, then signs the script.

.NOTES
    Requires: Administrator privileges (to install certificates to LocalMachine stores)

    After signing, set the execution policy to use signed scripts:
        Set-ExecutionPolicy AllSigned -Scope LocalMachine

    To verify a signature:
        Get-AuthenticodeSignature .\Robocurse.ps1

    To view installed certificates:
        Get-ChildItem Cert:\LocalMachine\TrustedPublisher
        Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert

    Self-signed certificates are only trusted on machines where you run this script.
    For multi-machine deployment, either:
    - Run this script on each machine
    - Export the cert and import it via GPO
    - Use a certificate from your organization's CA or a commercial CA

.LINK
    https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-authenticodesignature
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
