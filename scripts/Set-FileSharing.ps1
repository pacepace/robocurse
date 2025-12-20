#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables or disables the LanmanServer (Server) service for file sharing.

.DESCRIPTION
    Toggles the LanmanServer service startup type and starts/stops it accordingly.
    Use -Enable to allow file sharing, -Disable to prevent it.

.PARAMETER Enable
    Enable and start the LanmanServer service.

.PARAMETER Disable
    Stop and disable the LanmanServer service.

.PARAMETER Status
    Show current service status without making changes.

.EXAMPLE
    .\Set-FileSharing.ps1 -Enable

.EXAMPLE
    .\Set-FileSharing.ps1 -Disable

.EXAMPLE
    .\Set-FileSharing.ps1 -Status
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
