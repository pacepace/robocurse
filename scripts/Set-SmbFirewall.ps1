#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Blocks or allows SMB ports 139 and 445 in Windows Firewall.

.DESCRIPTION
    Creates or removes firewall rules to block inbound traffic on ports 139 and 445.
    Use -Block to deny SMB access, -Allow to permit it.

.PARAMETER Block
    Create firewall rules blocking ports 139 and 445.

.PARAMETER Allow
    Remove the blocking rules (allows SMB traffic).

.PARAMETER Status
    Show current firewall rule status without making changes.

.PARAMETER Delete
    Remove all Robocurse SMB firewall rules.

.PARAMETER Force
    Skip confirmation prompt when blocking.

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Block

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Allow

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Delete

.EXAMPLE
    .\Set-SmbFirewall.ps1 -Status
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
