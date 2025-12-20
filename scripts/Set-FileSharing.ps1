#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables or disables Windows file sharing by controlling the LanmanServer service.

.DESCRIPTION
    Controls the LanmanServer (Server) service, which is responsible for SMB file sharing
    on Windows. This is the service that allows other computers to access shared folders,
    admin shares (C$, ADMIN$), and printers on this machine.

    When disabled:
    - No one can access shared folders on this machine
    - Admin shares (\\server\c$) become inaccessible
    - PsExec and similar tools cannot connect
    - Remote MMC snap-ins lose access to file-based data

    When enabled:
    - Standard Windows file sharing is available
    - The service is set to start automatically on boot

    This script controls the service layer only. To block SMB at the firewall level
    (which is more secure), use Set-SmbFirewall.ps1 instead.

.PARAMETER Enable
    Sets the LanmanServer service to Automatic startup and starts it immediately.

.PARAMETER Disable
    Stops the LanmanServer service and sets it to Disabled startup.
    The service will not start on reboot.

.PARAMETER Status
    Displays the current service state and startup type without making changes.

.EXAMPLE
    .\Set-FileSharing.ps1 -Enable

    Enables file sharing and starts the service.

.EXAMPLE
    .\Set-FileSharing.ps1 -Disable

    Stops file sharing and prevents the service from starting on boot.

.EXAMPLE
    .\Set-FileSharing.ps1 -Status

    Shows the current state without making changes.

.NOTES
    Requires: Administrator privileges

    Related services:
    - LanmanServer (Server): Handles incoming SMB connections (this script)
    - LanmanWorkstation (Workstation): Handles outgoing SMB connections to other servers

    Disabling LanmanServer does NOT affect this machine's ability to connect to
    other file shares. It only prevents others from connecting to this machine.

    For defense in depth, combine with Set-SmbFirewall.ps1 to block at the
    firewall level as well.

.LINK
    Set-SmbFirewall.ps1
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$serviceName = 'LanmanServer'

function Get-ServiceStatus {
    $svc = Get-Service -Name $serviceName
    $startType = (Get-WmiObject Win32_Service -Filter "Name='$serviceName'").StartMode

    Write-Host "`nLanmanServer (File Sharing) Status:" -ForegroundColor Cyan
    Write-Host "  Service State: $($svc.Status)"
    Write-Host "  Startup Type:  $startType"

    if ($svc.Status -eq 'Running' -and $startType -ne 'Disabled') {
        Write-Host "  File Sharing:  ENABLED" -ForegroundColor Green
    } else {
        Write-Host "  File Sharing:  DISABLED" -ForegroundColor Yellow
    }
}

if (-not $Enable -and -not $Disable -and -not $Status) {
    Write-Host "Specify -Enable, -Disable, or -Status" -ForegroundColor Red
    Get-ServiceStatus
    exit 1
}

if ($Enable -and $Disable) {
    throw "Cannot specify both -Enable and -Disable"
}

if ($Status) {
    Get-ServiceStatus
    exit 0
}

if ($Enable) {
    Write-Host "Enabling LanmanServer service..." -ForegroundColor Cyan

    Set-Service -Name $serviceName -StartupType Automatic
    Start-Service -Name $serviceName

    Write-Host "LanmanServer enabled and started" -ForegroundColor Green
    Get-ServiceStatus
}

if ($Disable) {
    Write-Host "Disabling LanmanServer service..." -ForegroundColor Cyan

    $svc = Get-Service -Name $serviceName
    if ($svc.Status -eq 'Running') {
        Stop-Service -Name $serviceName -Force
    }
    Set-Service -Name $serviceName -StartupType Disabled

    Write-Host "LanmanServer stopped and disabled" -ForegroundColor Green
    Get-ServiceStatus
}
