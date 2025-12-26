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
    Path to a specific script to sign. If not specified, signs all Robocurse scripts
    found in the current directory (Robocurse.ps1, Sign-Robocurse.ps1, Set-*.ps1).
    Missing files are skipped gracefully.

.PARAMETER CertSubject
    Subject name for the certificate. Defaults to "Robocurse Signing".
    Change this if you want separate certificates for different scripts.

.PARAMETER Force
    Create a new certificate even if a valid one already exists.
    Use this if the existing certificate is compromised or you want to rotate keys.

.EXAMPLE
    .\Sign-Robocurse.ps1

    Signs all Robocurse scripts in the current directory, skipping any that are missing.

.EXAMPLE
    .\Sign-Robocurse.ps1 C:\Deploy\Robocurse.ps1

    Signs a specific script at the given path (positional argument).

.EXAMPLE
    .\Sign-Robocurse.ps1 -ScriptPath C:\Scripts\MyScript.ps1 -CertSubject "My Company Signing"

    Signs a specific script with a custom certificate name.

.EXAMPLE
    .\Sign-Robocurse.ps1 -Force

    Creates a new certificate even if one already exists, then signs all scripts.

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

# Known Robocurse scripts to sign when no specific path is given
$knownScripts = @(
    'Robocurse.ps1',
    'Sign-Robocurse.ps1',
    'Set-FileSharing.ps1',
    'Set-PsRemoting.ps1',
    'Set-SmbFirewall.ps1'
)

# Determine what to sign
$scriptsToSign = @()
$singleFileMode = $false

if ($ScriptPath) {
    # Specific file requested
    if (-not (Test-Path $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }
    $scriptsToSign = @($ScriptPath)
    $singleFileMode = $true
} else {
    # No path specified - find all known scripts in current directory
    $baseDir = Get-Location
    foreach ($scriptName in $knownScripts) {
        $fullPath = Join-Path $baseDir $scriptName
        if (Test-Path $fullPath) {
            $scriptsToSign += $fullPath
        }
    }

    if ($scriptsToSign.Count -eq 0) {
        Write-Host "No Robocurse scripts found in current directory." -ForegroundColor Yellow
        Write-Host "Looking for: $($knownScripts -join ', ')" -ForegroundColor Gray
        Write-Host "`nTo sign a specific file, use: .\Sign-Robocurse.ps1 <path>" -ForegroundColor Gray
        exit 0
    }
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

# Sign the scripts
if (-not $singleFileMode) {
    Write-Host "`nSigning scripts in current directory..." -ForegroundColor Cyan
    Write-Host "Found $($scriptsToSign.Count) of $($knownScripts.Count) known scripts" -ForegroundColor Gray
}

$signedCount = 0
$failedCount = 0

foreach ($script in $scriptsToSign) {
    $scriptName = Split-Path $script -Leaf
    Write-Host "`nSigning $scriptName..." -ForegroundColor Cyan

    $signParams = @{
        FilePath = $script
        Certificate = $cert
        TimestampServer = "https://timestamp.digicert.com"
        HashAlgorithm = "SHA256"
    }

    try {
        $signature = Set-AuthenticodeSignature @signParams

        if ($signature.Status -eq 'Valid') {
            Write-Host "  Signed successfully" -ForegroundColor Green
            $signedCount++
        } else {
            Write-Host "  Signing failed: $($signature.Status)" -ForegroundColor Red
            $failedCount++
        }
    } catch {
        Write-Host "  Error: $_" -ForegroundColor Red
        $failedCount++
    }
}

# Summary
Write-Host "`n" + ("=" * 50) -ForegroundColor Gray
if ($failedCount -eq 0) {
    Write-Host "Done! Signed $signedCount script(s) successfully." -ForegroundColor Green
} else {
    Write-Host "Done! Signed: $signedCount, Failed: $failedCount" -ForegroundColor Yellow
}

Write-Host "`nCertificate: $($cert.Subject)" -ForegroundColor Gray
Write-Host "Expires: $($cert.NotAfter)" -ForegroundColor Gray

# Verify all signed scripts
Write-Host "`nVerifying signatures..." -ForegroundColor Cyan
foreach ($script in $scriptsToSign) {
    $scriptName = Split-Path $script -Leaf
    $verify = Get-AuthenticodeSignature $script

    if ($verify.Status -eq 'Valid') {
        Write-Host "  $scriptName - Valid" -ForegroundColor Green
    } else {
        Write-Host "  $scriptName - $($verify.Status)" -ForegroundColor Yellow
    }
}
