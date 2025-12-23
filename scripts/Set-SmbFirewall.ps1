#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blocks or allows SMB traffic (ports 139 and 445) at the Windows Firewall level.

.DESCRIPTION
    Creates or removes Windows Firewall rules to block inbound SMB traffic.
    This provides network-level protection that works even if the LanmanServer
    service is running.

    SMB (Server Message Block) is used for:
    - File sharing (shared folders, admin shares like C$ and ADMIN$)
    - Named pipes (used by many Windows services and tools)
    - Printer sharing

    When blocked, the following will stop working FROM OTHER MACHINES:
    - Access to shared folders on this server
    - Admin shares (\\server\c$, \\server\admin$)
    - PsExec and similar remote execution tools
    - Remote Registry access
    - Event Viewer remote log access
    - Other MMC snap-in features that fetch data over SMB

    The following will STILL WORK:
    - RDP (Remote Desktop) - uses port 3389
    - PowerShell Remoting (WinRM) - uses port 5985/5986
    - Core MMC operations that use RPC - uses port 135
    - This machine connecting to OTHER file shares (outbound SMB)

    This script only manages rules it creates (named Robocurse-Block-SMB-*).
    It does not modify any other firewall rules.

.PARAMETER Block
    Creates firewall rules to block inbound TCP traffic on ports 139 and 445.
    Prompts for confirmation unless -Force is specified.

.PARAMETER Allow
    Removes the Robocurse block rules, allowing SMB traffic.
    Equivalent to -Delete.

.PARAMETER Delete
    Removes all Robocurse SMB firewall rules.
    Equivalent to -Allow.

.PARAMETER Status
    Displays the current state of Robocurse SMB firewall rules without making changes.

.PARAMETER Force
    Skips the confirmation prompt when using -Block.
    Useful for scripted/automated deployments.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Block

    Blocks SMB ports after showing a warning and prompting for confirmation.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Block -Force

    Blocks SMB ports without prompting. Use in scripts or scheduled tasks.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Allow

    Removes the block rules, allowing SMB traffic again.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Status

    Shows whether SMB is currently blocked without making changes.

.NOTES
    Requires: Administrator privileges

    Firewall rules created by this script:
    - Robocurse-Block-SMB-139 (NetBIOS Session Service)
    - Robocurse-Block-SMB-445 (SMB Direct / CIFS)

    For complete SMB lockdown, also disable the LanmanServer service using
    Set-FileSharing.ps1 -Disable. Defense in depth.

    Port 139 is NetBIOS over TCP, used by older SMB1 clients.
    Port 445 is SMB Direct, used by SMB2/SMB3 and modern Windows.
    Both are blocked for comprehensive protection.

    This script blocks INBOUND traffic only. This machine can still connect
    to file shares on other servers.

.LINK
    Set-FileSharing.ps1
    Set-PsRemoting.ps1
#>
[CmdletBinding()]
param(
    [switch]$Block,
    [switch]$Allow,
    [switch]$Delete,
    [switch]$Status,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$rules = @(
    @{
        Name = 'Robocurse-Block-SMB-139'
        DisplayName = 'Block SMB NetBIOS (139)'
        Port = 139
    },
    @{
        Name = 'Robocurse-Block-SMB-445'
        DisplayName = 'Block SMB Direct (445)'
        Port = 445
    }
)

function Get-FirewallStatus {
    Write-Host "`nSMB Firewall Rules Status:" -ForegroundColor Cyan

    $allBlocked = $true
    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  $($rule.DisplayName): BLOCKED" -ForegroundColor Yellow
        } else {
            Write-Host "  $($rule.DisplayName): ALLOWED (no block rule)" -ForegroundColor Green
            $allBlocked = $false
        }
    }

    if ($allBlocked) {
        Write-Host "`n  SMB Access: BLOCKED" -ForegroundColor Yellow
    } else {
        Write-Host "`n  SMB Access: ALLOWED" -ForegroundColor Green
    }
}

if (-not $Block -and -not $Allow -and -not $Delete -and -not $Status) {
    Write-Host "Specify -Block, -Allow, -Delete, or -Status" -ForegroundColor Red
    Get-FirewallStatus
    exit 1
}

$actionCount = @($Block, $Allow, $Delete).Where({ $_ }).Count
if ($actionCount -gt 1) {
    throw "Cannot specify multiple actions. Choose one of: -Block, -Allow, -Delete"
}

if ($Status) {
    Get-FirewallStatus
    exit 0
}

if ($Block) {
    if (-not $Force) {
        Write-Host "`nWARNING: Blocking SMB ports will break:" -ForegroundColor Yellow
        Write-Host "  - Admin shares (\\server\c$, \\server\admin$)" -ForegroundColor Yellow
        Write-Host "  - File sharing" -ForegroundColor Yellow
        Write-Host "  - PsExec and similar tools" -ForegroundColor Yellow
        Write-Host "  - Remote Registry, Event Viewer, and other MMC snap-in features" -ForegroundColor Yellow
        Write-Host "    (MMC uses RPC on port 135, but many snap-ins fetch data over SMB)" -ForegroundColor DarkYellow
        Write-Host "`nStill works: RDP, PowerShell Remoting, core MMC/RPC operations`n" -ForegroundColor Cyan

        $confirm = Read-Host "Are you sure? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Host "Cancelled." -ForegroundColor Cyan
            exit 0
        }
    }

    Write-Host "Blocking SMB ports 139 and 445..." -ForegroundColor Cyan

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Host "  $($rule.DisplayName) rule already exists" -ForegroundColor Cyan
        } else {
            New-NetFirewallRule -Name $rule.Name `
                -DisplayName $rule.DisplayName `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $rule.Port `
                -Action Block `
                -Profile Any `
                -Description "Created by Robocurse Set-SmbFirewall.ps1" | Out-Null

            Write-Host "  Created: $($rule.DisplayName)" -ForegroundColor Green
        }
    }

    Write-Host "`nSMB ports blocked" -ForegroundColor Green
    Get-FirewallStatus
}

if ($Allow -or $Delete) {
    $action = if ($Delete) { "Deleting" } else { "Removing" }
    Write-Host "$action SMB block rules..." -ForegroundColor Cyan

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue

        if ($existing) {
            Remove-NetFirewallRule -Name $rule.Name
            Write-Host "  Removed: $($rule.DisplayName)" -ForegroundColor Green
        } else {
            Write-Host "  $($rule.DisplayName) rule not found" -ForegroundColor Cyan
        }
    }

    Write-Host "`nSMB block rules removed" -ForegroundColor Green
    Get-FirewallStatus
}
